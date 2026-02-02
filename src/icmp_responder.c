#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <netinet/ip.h>
#include <netinet/ip_icmp.h>
#include <curl/curl.h>
#include <time.h>
#include <errno.h>
#include <signal.h>

#define VERSION "7.0.0 (Marked Reply)"
#define REPLY_MARK 100

char *CONFIG_FILE = NULL;
char PHY_IF[32] = {0};
char TUN_DEV[32] = {0};
char GATEWAY_IP[32] = {0}; 
char ICMP_RES_IP[32] = {0}; 
char LOG_FILE[128] = {0};
int WORKER_COUNT = 5;
int PROBE_INTERVAL = 2000;
char **PROBE_URLS = NULL;
int URL_COUNT = 0;

volatile int IS_ONLINE = 0;
volatile long CURRENT_LATENCY = 0;
volatile int RUNNING = 1;

void log_msg(const char *format, ...) {
    if (strlen(LOG_FILE) == 0) return;
    FILE *fp = fopen(LOG_FILE, "a");
    if (!fp) return;
    time_t now = time(NULL);
    struct tm *t = localtime(&now);
    char time_str[64];
    strftime(time_str, sizeof(time_str), "%Y-%m-%d %H:%M:%S", t);
    fprintf(fp, "[%s] ", time_str);
    va_list args;
    va_start(args, format);
    vfprintf(fp, format, args);
    va_end(args);
    fprintf(fp, "\n");
    fclose(fp);
}

void parse_config() {
    FILE *fp = fopen(CONFIG_FILE, "r");
    if (!fp) exit(1);
    char line[1024];
    while (fgets(line, sizeof(line), fp)) {
        if (strncmp(line, "PROBE_URLS=", 11) == 0) {
            char *urls = strdup(line + 11);
            urls[strcspn(urls, "\n")] = 0; 
            char *token = strtok(urls, ",");
            while (token) {
                PROBE_URLS = realloc(PROBE_URLS, sizeof(char*) * (URL_COUNT + 1));
                PROBE_URLS[URL_COUNT++] = strdup(token);
                token = strtok(NULL, ",");
            }
            free(urls);
        }
        else if (strncmp(line, "probe_interval_ms=", 18) == 0) PROBE_INTERVAL = atoi(line + 18);
        else if (strncmp(line, "worker_count=", 13) == 0) WORKER_COUNT = atoi(line + 13);
    }
    fclose(fp);
}

void *prober_thread(void *arg) {
    CURL *curl;
    curl = curl_easy_init();
    if (!curl) return NULL;

    while (RUNNING) {
        int successful_probes = 0;
        long total_latency = 0;
        for (int i = 0; i < URL_COUNT; i++) {
            curl_easy_setopt(curl, CURLOPT_URL, PROBE_URLS[i]);
            curl_easy_setopt(curl, CURLOPT_TIMEOUT_MS, 5000L);
            curl_easy_setopt(curl, CURLOPT_NOBODY, 1L);
            curl_easy_setopt(curl, CURLOPT_INTERFACE, GATEWAY_IP); 
            curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
            if (curl_easy_perform(curl) == CURLE_OK) {
                double val;
                curl_easy_getinfo(curl, CURLINFO_TOTAL_TIME, &val);
                total_latency += (long)(val * 1000);
                successful_probes++;
            }
        }
        if (successful_probes > 0) {
            IS_ONLINE = 1;
            CURRENT_LATENCY = total_latency / successful_probes;
            log_msg("DEBUG: Latency: %ldms", CURRENT_LATENCY);
        } else {
            IS_ONLINE = 0;
            CURRENT_LATENCY = 0;
            log_msg("DEBUG: Probes Failed.");
        }
        usleep(PROBE_INTERVAL * 1000);
    }
    curl_easy_cleanup(curl);
    return NULL;
}

unsigned short checksum(void *b, int len) {
    unsigned short *buf = b;
    unsigned int sum = 0;
    unsigned short result;
    for (sum = 0; len > 1; len -= 2) sum += *buf++;
    if (len == 1) sum += *(unsigned char *)buf;
    sum = (sum >> 16) + (sum & 0xFFFF);
    sum += (sum >> 16);
    result = ~sum;
    return result;
}

void *icmp_listener(void *arg) {
    int sockfd, reply_sock;
    unsigned char buf[1024];
    char *LISTEN_IP = (strlen(ICMP_RES_IP) > 0) ? ICMP_RES_IP : GATEWAY_IP;

    // 1. Listening Socket (Input)
    sockfd = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (sockfd < 0) exit(1);
    
    // 2. Reply Socket (Output)
    reply_sock = socket(AF_INET, SOCK_RAW, IPPROTO_ICMP);
    if (reply_sock < 0) exit(1);

    // BIND reply socket to VIP
    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_addr.s_addr = inet_addr(LISTEN_IP);
    if (bind(reply_sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        log_msg("FATAL: Bind failed"); exit(1);
    }

    // SET MARK (This gets it past the firewall)
    int mark = REPLY_MARK;
    if (setsockopt(reply_sock, SOL_SOCKET, SO_MARK, &mark, sizeof(mark)) < 0) {
        log_msg("FATAL: Failed to set SO_MARK"); exit(1);
    }

    int one = 1;
    setsockopt(sockfd, IPPROTO_IP, IP_HDRINCL, &one, sizeof(one));

    log_msg("RESPONDER %s READY (Mark %d). Listening for %s", VERSION, REPLY_MARK, LISTEN_IP);

    while (RUNNING) {
        struct sockaddr_in saddr;
        socklen_t saddr_len = sizeof(saddr);
        int len = recvfrom(sockfd, buf, sizeof(buf), 0, (struct sockaddr*)&saddr, &saddr_len);
        if (len <= 0) continue;

        struct iphdr *ip = (struct iphdr *)buf;
        struct icmphdr *icmp = (struct icmphdr *)(buf + (ip->ihl * 4));
        if (icmp->type != ICMP_ECHO) continue;
        
        struct in_addr dest_ip; dest_ip.s_addr = ip->daddr;
        if (strcmp(inet_ntoa(dest_ip), LISTEN_IP) != 0) continue;

        log_msg("DEBUG: Recv Ping from %s", inet_ntoa(saddr.sin_addr));

        if (!IS_ONLINE) continue;

        if (CURRENT_LATENCY > 0) {
            usleep(CURRENT_LATENCY * 1000);
        }

        // Construct Payload
        int icmp_len = len - (ip->ihl * 4);
        unsigned char reply_buf[1024];
        struct icmphdr *reply_icmp = (struct icmphdr *)reply_buf;
        memcpy(reply_buf, icmp, icmp_len);
        
        reply_icmp->type = ICMP_ECHOREPLY;
        reply_icmp->checksum = 0;
        reply_icmp->checksum = checksum(reply_icmp, icmp_len);

        // Send (Marked)
        int sent = sendto(reply_sock, reply_buf, icmp_len, 0, (struct sockaddr *)&saddr, sizeof(saddr));
        if (sent > 0) {
            log_msg("DEBUG: Sent Reply to %s", inet_ntoa(saddr.sin_addr));
        } else {
            log_msg("ERROR: Send failed: %s", strerror(errno));
        }
    }
    return NULL;
}

void handle_signal(int sig) { RUNNING = 0; }

int main(int argc, char *argv[]) {
    signal(SIGINT, handle_signal);
    signal(SIGTERM, handle_signal);
    int opt;
    while ((opt = getopt(argc, argv, "c:i:e:g:v:l:")) != -1) {
        switch (opt) {
            case 'c': CONFIG_FILE = strdup(optarg); break;
            case 'i': strncpy(PHY_IF, optarg, 31); break;
            case 'e': strncpy(TUN_DEV, optarg, 31); break;
            case 'g': strncpy(GATEWAY_IP, optarg, 31); break;
            case 'v': strncpy(ICMP_RES_IP, optarg, 31); break;
            case 'l': strncpy(LOG_FILE, optarg, 127); break;
        }
    }
    parse_config();
    pthread_t p, i;
    pthread_create(&p, NULL, prober_thread, NULL);
    pthread_create(&i, NULL, icmp_listener, NULL);
    pthread_join(p, NULL);
    pthread_join(i, NULL);
    return 0;
}
