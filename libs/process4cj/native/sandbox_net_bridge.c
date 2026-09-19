#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/prctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

#define MAX_RULES 128
#define MAX_BRIDGE_WORKERS 128
#define MAX_GATEWAY_WORKERS 128
#define MAX_PRIVATE 16
#define MAX_HEADER 16384
#define BUFFER_SIZE 8192
#define POLL_TIMEOUT_MS 100

typedef struct {
    int family;
    union {
        struct in_addr ipv4;
        struct in6_addr ipv6;
    } address;
} private_address_t;

typedef struct {
    char host[256];
    uint16_t port;
    private_address_t private_addresses[MAX_PRIVATE];
    size_t private_count;
} rule_t;

typedef struct {
    rule_t rules[MAX_RULES];
    size_t count;
} policy_t;

static void die(const char *message) {
    fprintf(stderr, "sandbox-net-bridge: %s: %s\n", message, strerror(errno));
    exit(127);
}


static int write_all(int fd, const void *data, size_t length) {
    const unsigned char *bytes = (const unsigned char *)data;
    while (length > 0) {
        ssize_t written = write(fd, bytes, length);
        if (written < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (written == 0) return -1;
        bytes += written;
        length -= (size_t)written;
    }
    return 0;
}

static ssize_t read_until_headers(int fd, char *buffer, size_t capacity) {
    size_t used = 0;
    while (used < capacity) {
        ssize_t count = read(fd, buffer + used, capacity - used);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (count == 0) return (ssize_t)used;
        used += (size_t)count;
        buffer[used] = '\0';
        if (used >= 4 && strstr(buffer, "\r\n\r\n") != NULL) return (ssize_t)used;
    }
    return -2;
}

static int relay(int left, int right) {
    struct pollfd fds[2] = {
        {.fd = left, .events = POLLIN},
        {.fd = right, .events = POLLIN},
    };
    unsigned char buffer[BUFFER_SIZE];
    bool left_open = true;
    bool right_open = true;
    while (left_open || right_open) {
        fds[0].events = left_open ? POLLIN : 0;
        fds[1].events = right_open ? POLLIN : 0;
        int ready = poll(fds, 2, -1);
        if (ready < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (left_open && (fds[0].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = read(left, buffer, sizeof(buffer));
            if (count <= 0) {
                left_open = false;
                shutdown(right, SHUT_WR);
            } else if (write_all(right, buffer, (size_t)count) < 0) {
                return -1;
            }
        }
        if (right_open && (fds[1].revents & (POLLIN | POLLHUP | POLLERR))) {
            ssize_t count = read(right, buffer, sizeof(buffer));
            if (count <= 0) {
                right_open = false;
                shutdown(left, SHUT_WR);
            } else if (write_all(left, buffer, (size_t)count) < 0) {
                return -1;
            }
        }
    }
    return 0;
}

static void normalize_host(char *host) {
    size_t length = strlen(host);
    while (length > 0 && host[length - 1] == '.') host[--length] = '\0';
    for (size_t i = 0; i < length; ++i) {
        if (host[i] >= 'A' && host[i] <= 'Z') host[i] = (char)(host[i] + ('a' - 'A'));
    }
}

static bool host_equal(const char *left, const char *right) {
    char a[256];
    char b[256];
    snprintf(a, sizeof(a), "%s", left);
    snprintf(b, sizeof(b), "%s", right);
    normalize_host(a);
    normalize_host(b);
    return strcmp(a, b) == 0;
}

static bool parse_port(const char *text, uint16_t *port) {
    char *end = NULL;
    errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0' || value == 0 || value > 65535) return false;
    *port = (uint16_t)value;
    return true;
}

static bool is_ipv4_private_or_reserved(struct in_addr address) {
    uint32_t value = ntohl(address.s_addr);
    uint32_t first = value >> 24;
    uint32_t second = (value >> 16) & 0xffu;
    uint32_t third = (value >> 8) & 0xffu;
    uint32_t fourth = value & 0xffu;
    if (first == 168 && second == 63 && third == 129 && fourth == 16) return true;
    if (first == 0 || first == 10 || first == 127 || first >= 224) return true;
    if (first == 100 && second >= 64 && second <= 127) return true;
    if (first == 169 && second == 254) return true;
    if (first == 172 && second >= 16 && second <= 31) return true;
    if (first == 192 && (
        second == 168 ||
        (second == 0 && (third == 0 || third == 2)) ||
        (second == 88 && third == 99)
    )) return true;
    if (first == 198 && (
        second == 18 || second == 19 ||
        (second == 51 && third == 100)
    )) return true;
    if (first == 203 && second == 0 && third == 113) return true;
    return false;
}

static bool is_ipv6_allowed_global(const struct in6_addr *address) {
    const unsigned char *bytes = address->s6_addr;
    if ((bytes[0] & 0xe0u) != 0x20u) return false;
    // Exclude the reserved IPv6 ranges after DNS resolution, not only when
    // the original policy host was a literal.
    if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] < 0x02) return false;
    if (bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8) return false;
    if (bytes[0] == 0x20 && bytes[1] == 0x02) return false;
    if (bytes[0] == 0x3f && bytes[1] == 0xff && (bytes[2] & 0xf0u) == 0x00u) return false;
    if (bytes[0] == 0xfc || bytes[0] == 0xfd || bytes[0] == 0xfe || bytes[0] == 0xff) return false;
    return true;
}

static bool private_address_matches(const void *raw, int family, const rule_t *rule) {
    for (size_t i = 0; i < rule->private_count; ++i) {
        const private_address_t *candidate = &rule->private_addresses[i];
        if (candidate->family == family) {
            const void *configured = family == AF_INET
                ? (const void *)&candidate->address.ipv4
                : (const void *)&candidate->address.ipv6;
            size_t length = family == AF_INET
                ? sizeof(struct in_addr)
                : sizeof(struct in6_addr);
            if (memcmp(raw, configured, length) == 0) return true;
            continue;
        }
        if (family == AF_INET && candidate->family == AF_INET6 &&
            IN6_IS_ADDR_V4MAPPED(&candidate->address.ipv6) &&
            memcmp(((const struct in6_addr *) &candidate->address.ipv6)->s6_addr + 12,
                raw, sizeof(struct in_addr)) == 0) return true;
        if (family == AF_INET6 && candidate->family == AF_INET &&
            IN6_IS_ADDR_V4MAPPED((const struct in6_addr *) raw) &&
            memcmp(((const struct in6_addr *) raw)->s6_addr + 12,
                &candidate->address.ipv4, sizeof(struct in_addr)) == 0) return true;
    }
    return false;
}

static bool address_is_allowed(const struct sockaddr *address, const rule_t *rule) {
    const void *raw = NULL;
    int family = address->sa_family;
    if (family == AF_INET) {
        raw = &((const struct sockaddr_in *)address)->sin_addr;
    } else if (family == AF_INET6) {
        raw = &((const struct sockaddr_in6 *)address)->sin6_addr;
    } else {
        return false;
    }
    if (private_address_matches(raw, family, rule)) return true;
    if (family == AF_INET) return !is_ipv4_private_or_reserved(*(const struct in_addr *)raw);
    return is_ipv6_allowed_global((const struct in6_addr *)raw);
}

static bool egress_rule_matches(const rule_t *rule, const char *host, uint16_t port) {
    return rule->port == port && host_equal(rule->host, host);
}

static int connect_destination(const policy_t *policy, const char *host, uint16_t port) {
    bool matching_rule = false;
    for (size_t i = 0; i < policy->count; ++i) {
        if (egress_rule_matches(&policy->rules[i], host, port)) {
            matching_rule = true;
            break;
        }
    }
    if (!matching_rule) return -2;
    char port_text[16];
    snprintf(port_text, sizeof(port_text), "%u", (unsigned)port);
    struct addrinfo hints;
    memset(&hints, 0, sizeof(hints));
    hints.ai_socktype = SOCK_STREAM;
    hints.ai_family = AF_UNSPEC;
    struct addrinfo *addresses = NULL;
    int lookup = getaddrinfo(host, port_text, &hints, &addresses);
    if (lookup != 0) return -3;
    int connected = -1;
    for (struct addrinfo *entry = addresses; entry != NULL; entry = entry->ai_next) {
        bool address_allowed = false;
        for (size_t i = 0; i < policy->count; ++i) {
            const rule_t *rule = &policy->rules[i];
            if (!egress_rule_matches(rule, host, port)) continue;
            if (address_is_allowed(entry->ai_addr, rule)) {
                address_allowed = true;
                break;
            }
        }
        if (!address_allowed) continue;
        int fd = socket(entry->ai_family, entry->ai_socktype, entry->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, entry->ai_addr, entry->ai_addrlen) == 0) {
            connected = fd;
            break;
        }
        close(fd);
    }
    freeaddrinfo(addresses);
    return connected;
}

static int read_line(int fd, char *buffer, size_t capacity) {
    size_t used = 0;
    while (used + 1 < capacity) {
        char byte;
        ssize_t count = read(fd, &byte, 1);
        if (count < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        if (count == 0) return 0;
        buffer[used++] = byte;
        if (byte == '\n') {
            buffer[used] = '\0';
            return (int)used;
        }
    }
    return -2;
}

static int gateway_connection(int fd, const policy_t *policy) {
    char host[256];
    char port_text[16];
    if (read_line(fd, host, sizeof(host)) <= 0 || read_line(fd, port_text, sizeof(port_text)) <= 0) return -1;
    host[strcspn(host, "\r\n")] = '\0';
    port_text[strcspn(port_text, "\r\n")] = '\0';
    uint16_t port;
    if (!parse_port(port_text, &port) || host[0] == '\0') {
        write_all(fd, "ERR\n", 4);
        return -1;
    }
    int destination = connect_destination(policy, host, port);
    if (destination < 0) {
        write_all(fd, "ERR\n", 4);
        return -1;
    }
    if (write_all(fd, "OK\n", 3) < 0) {
        close(destination);
        return -1;
    }
    int result = relay(fd, destination);
    close(destination);
    return result;
}
static void gateway_reap_workers(pid_t *workers, size_t *count) {
    size_t index = 0;
    while (index < *count) {
        int status = 0;
        pid_t result = waitpid(workers[index], &status, WNOHANG);
        if (result == workers[index] || (result < 0 && errno == ECHILD)) {
            workers[index] = workers[*count - 1];
            --(*count);
            continue;
        }
        ++index;
    }
}

static void gateway_stop_workers(pid_t *workers, size_t *count) {
    for (size_t index = 0; index < *count; ++index) {
        (void)kill(workers[index], SIGTERM);
    }
    while (*count > 0) {
        int status = 0;
        pid_t result = waitpid(workers[0], &status, 0);
        if (result == workers[0] || (result < 0 && errno == ECHILD)) {
            workers[0] = workers[*count - 1];
            --(*count);
        } else if (result < 0 && errno == EINTR) {
            continue;
        } else {
            break;
        }
    }
}

static int run_gateway(const char *socket_path, const policy_t *policy) {
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) die("cannot create gateway socket");
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof(address.sun_path)) {
        close(server);
        fprintf(stderr, "sandbox-net-bridge: gateway socket path is too long\n");
        return 2;
    }
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", socket_path);
    unlink(socket_path);
    umask(0077);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(server, 64) < 0) die("cannot bind gateway socket");
    chmod(socket_path, 0600);
    signal(SIGPIPE, SIG_IGN);
    pid_t workers[MAX_GATEWAY_WORKERS];
    size_t worker_count = 0;
    while (true) {
        gateway_reap_workers(workers, &worker_count);
        int client = accept(server, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR) continue;
            gateway_stop_workers(workers, &worker_count);
            close(server);
            unlink(socket_path);
            return 1;
        }
        if (worker_count >= MAX_GATEWAY_WORKERS) {
            close(client);
            continue;
        }
        pid_t parent_pid = getpid();
        pid_t child = fork();
        if (child == 0) {
            close(server);
            if (prctl(PR_SET_PDEATHSIG, SIGKILL) != 0 || getppid() != parent_pid) _exit(127);
            int result = gateway_connection(client, policy);
            close(client);
            _exit(result == 0 ? 0 : 1);
        }
        close(client);
        if (child > 0) workers[worker_count++] = child;
        gateway_reap_workers(workers, &worker_count);
    }
}

static bool parse_proxy_authority(const char *authority, char *host, size_t host_size, uint16_t *port, uint16_t default_port) {
    if (authority == NULL || authority[0] == '\0') return false;
    char value[512];
    snprintf(value, sizeof(value), "%s", authority);
    char *start = value;
    while (*start == ' ' || *start == '\t') ++start;
    char *end = start + strlen(start);
    while (end > start && (end[-1] == ' ' || end[-1] == '\t' || end[-1] == '\r' || end[-1] == '\n')) --end;
    *end = '\0';
    if (start[0] == '[') {
        char *close = strchr(start, ']');
        if (close == NULL) return false;
        *close = '\0';
        snprintf(host, host_size, "%s", start + 1);
        if (close[1] == ':') return parse_port(close + 2, port);
        *port = default_port;
        return true;
    }
    char *colon = strrchr(start, ':');
    if (colon != NULL && strchr(start, ':') == colon) {
        *colon = '\0';
        if (!parse_port(colon + 1, port)) return false;
    } else {
        *port = default_port;
    }
    snprintf(host, host_size, "%s", start);
    return host[0] != '\0';
}

static bool find_header_value(const char *headers, const char *name, char *value, size_t value_size) {
    const char *cursor = headers;
    size_t name_length = strlen(name);
    while (*cursor != 0) {
        if ((cursor == headers || cursor[-1] == '\n') &&
            strncasecmp(cursor, name, name_length) == 0 &&
            cursor[name_length] == ':') {
            const char *value_start = cursor + name_length + 1;
            while (*value_start == ' ' || *value_start == '\t') ++value_start;
            const char *end = strstr(value_start, "\r\n");
            if (end == NULL) end = strchr(value_start, '\n');
            if (end == NULL) return false;
            size_t length = (size_t)(end - value_start);
            while (length > 0 && (value_start[length - 1] == ' ' || value_start[length - 1] == '\t')) --length;
            if (length + 1 > value_size) return false;
            memcpy(value, value_start, length);
            value[length] = '\0';
            return true;
        }
        const char *line_end = strchr(cursor, '\n');
        if (line_end == NULL) break;
        cursor = line_end + 1;
    }
    return false;
}

static int connect_gateway(const char *socket_path, const char *host, uint16_t port) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof(address.sun_path)) {
        close(fd);
        return -1;
    }
    snprintf(address.sun_path, sizeof(address.sun_path), "%s", socket_path);
    if (connect(fd, (struct sockaddr *)&address, sizeof(address)) < 0) {
        close(fd);
        return -1;
    }
    char request[768];
    int length = snprintf(request, sizeof(request), "%s\n%u\n", host, (unsigned)port);
    if (length <= 0 || (size_t)length >= sizeof(request) || write_all(fd, request, (size_t)length) < 0) {
        close(fd);
        return -1;
    }
    char response[4] = {0};
    size_t used = 0;
    while (used < 3) {
        ssize_t count = read(fd, response + used, 3 - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            close(fd);
            return -1;
        }
        used += (size_t)count;
        if (used == 3) break;
    }
    if (memcmp(response, "OK\n", 3) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int rewrite_proxy_request(const char *headers, size_t length, char *output, size_t capacity) {
    const char *line_end = strstr(headers, "\r\n");
    if (line_end == NULL) return -1;
    const char *first_space = strchr(headers, ' ');
    if (first_space == NULL || first_space > line_end) return -1;
    const char *target = first_space + 1;
    const char *target_end = strchr(target, ' ');
    if (target_end == NULL || target_end > line_end) return -1;
    if (strncmp(target, "http://", 7) != 0 && strncmp(target, "https://", 8) != 0) {
        if (length + 1 > capacity) return -1;
        memcpy(output, headers, length);
        output[length] = '\0';
        return (int)length;
    }
    const char *authority_start = target + (target[4] == ':' ? 7 : 8);
    const char *path = strchr(authority_start, '/');
    const char *query = strchr(authority_start, '?');
    if (path == NULL || (query != NULL && query < path)) path = query;
    bool default_path = path == NULL || path >= target_end;
    bool query_only_path = !default_path && *path == '?';
    size_t prefix_length = (size_t)(first_space - headers + 1);
    size_t path_length = default_path ? 1 : (size_t)(target_end - path);
    size_t rewritten_path_length = path_length + (query_only_path ? 1 : 0);
    size_t suffix_length = length - (size_t)(target_end - headers);
    if (prefix_length + rewritten_path_length + suffix_length + 1 > capacity) return -1;
    memcpy(output, headers, prefix_length);
    if (default_path) {
        memcpy(output + prefix_length, "/", 1);
    } else if (query_only_path) {
        memcpy(output + prefix_length, "/", 1);
        memcpy(output + prefix_length + 1, path, path_length);
    } else {
        memcpy(output + prefix_length, path, path_length);
    }
    memcpy(output + prefix_length + rewritten_path_length, target_end, suffix_length);
    output[prefix_length + rewritten_path_length + suffix_length] = '\0';
    return (int)(prefix_length + rewritten_path_length + suffix_length);
}
static int proxy_connection(int client, const char *socket_path) {
    char headers[MAX_HEADER + 1];
    ssize_t length = read_until_headers(client, headers, MAX_HEADER);
    if (length <= 0 || length == -2) return -1;
    headers[length] = '\0';
    char method[32];
    char authority[512];
    if (sscanf(headers, "%31s %511s", method, authority) != 2) return -1;
    bool connect_method = strcasecmp(method, "CONNECT") == 0;
    char host[256];
    uint16_t port;
    if (!parse_proxy_authority(connect_method ? authority : NULL, host, sizeof(host), &port, 443)) {
        char host_header[512];
        if (!find_header_value(headers, "Host", host_header, sizeof(host_header)) ||
            !parse_proxy_authority(host_header, host, sizeof(host), &port, 80)) return -1;
    }
    int gateway = connect_gateway(socket_path, host, port);
    if (gateway < 0) {
        static const char forbidden[] = "HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n";
        write_all(client, forbidden, strlen(forbidden));
        return -1;
    }
    if (connect_method) {
        static const char established[] = "HTTP/1.1 200 Connection Established\r\n\r\n";
        if (write_all(client, established, strlen(established)) < 0) {
            close(gateway);
            return -1;
        }
    } else {
        char forwarded[MAX_HEADER + 1];
        int forwarded_length = rewrite_proxy_request(headers, (size_t)length, forwarded, sizeof(forwarded));
        if (forwarded_length < 0 || write_all(gateway, forwarded, (size_t)forwarded_length) < 0) {
            close(gateway);
            return -1;
        }
    }
    int result = relay(client, gateway);
    close(gateway);
    return result;
}

static void reap_bridge_workers(pid_t *workers, size_t *count) {
    size_t index = 0;
    while (index < *count) {
        int status = 0;
        pid_t waited = waitpid(workers[index], &status, WNOHANG);
        if (waited == workers[index] || (waited < 0 && errno == ECHILD)) {
            workers[index] = workers[*count - 1];
            --*count;
            continue;
        }
        if (waited < 0 && errno == EINTR) continue;
        ++index;
    }
}

static void stop_bridge_workers(pid_t *workers, size_t count) {
    for (size_t index = 0; index < count; ++index) {
        if (kill(workers[index], SIGTERM) < 0 && errno != ESRCH) continue;
    }
    for (size_t index = 0; index < count; ++index) {
        while (waitpid(workers[index], NULL, 0) < 0 && errno == EINTR) {}
    }
}

static int run_bridge(const char *socket_path, char **target) {
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) die("cannot create bridge listener");
    int reuse = 1;
    setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    struct sockaddr_in address;
    memset(&address, 0, sizeof(address));
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    address.sin_port = 0;
    if (bind(listener, (struct sockaddr *)&address, sizeof(address)) < 0 || listen(listener, 32) < 0) die("cannot bind bridge listener");
    socklen_t address_length = sizeof(address);
    if (getsockname(listener, (struct sockaddr *)&address, &address_length) < 0) die("cannot read bridge listener port");
    char proxy_url[64];
    snprintf(proxy_url, sizeof(proxy_url), "http://127.0.0.1:%u", (unsigned)ntohs(address.sin_port));
    setenv("HTTP_PROXY", proxy_url, 1);
    setenv("http_proxy", proxy_url, 1);
    setenv("HTTPS_PROXY", proxy_url, 1);
    setenv("https_proxy", proxy_url, 1);
    setenv("ALL_PROXY", proxy_url, 1);
    setenv("all_proxy", proxy_url, 1);
    setenv("NO_PROXY", "", 1);
    setenv("no_proxy", "", 1);
    signal(SIGPIPE, SIG_IGN);
    pid_t child = fork();
    if (child < 0) die("cannot launch bridged command");
    if (child == 0) {
        close(listener);
        execvp(target[0], target);
        _exit(127);
    }
    pid_t workers[MAX_BRIDGE_WORKERS];
    size_t worker_count = 0;
    int status = 127;
    bool running = true;
    while (running) {
        struct pollfd pollfd = {.fd = listener, .events = POLLIN};
        int ready = poll(&pollfd, 1, POLL_TIMEOUT_MS);
        if (ready > 0 && (pollfd.revents & POLLIN)) {
            int client = accept(listener, NULL, NULL);
            if (client >= 0) {
                if (worker_count >= MAX_BRIDGE_WORKERS) {
                    close(client);
                } else {
                    pid_t worker = fork();
                    if (worker == 0) {
                        close(listener);
                        int result = proxy_connection(client, socket_path);
                        close(client);
                        _exit(result == 0 ? 0 : 1);
                    }
                    if (worker > 0) workers[worker_count++] = worker;
                    close(client);
                }
            }
        }
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) running = false;
        if (waited < 0 && errno == ECHILD) {
            status = 127;
            running = false;
        }
        reap_bridge_workers(workers, &worker_count);
    }
    close(listener);
    stop_bridge_workers(workers, worker_count);
    if (WIFEXITED(status)) return WEXITSTATUS(status);
    if (WIFSIGNALED(status)) return 128 + WTERMSIG(status);
    return 127;
}

static bool parse_policy(int argc, char **argv, int start, policy_t *policy) {
    memset(policy, 0, sizeof(*policy));
    int index = start;
    while (index < argc) {
        if (strcmp(argv[index], "--rule") != 0 || index + 3 >= argc || policy->count >= MAX_RULES) return false;
        rule_t *rule = &policy->rules[policy->count++];
        snprintf(rule->host, sizeof(rule->host), "%s", argv[index + 1]);
        normalize_host(rule->host);
        if (!parse_port(argv[index + 2], &rule->port)) return false;
        const char *private_text = argv[index + 3];
        if (strcmp(private_text, "-") != 0) {
            char values[1024];
            snprintf(values, sizeof(values), "%s", private_text);
            char *save = NULL;
            for (char *item = strtok_r(values, ",", &save); item != NULL; item = strtok_r(NULL, ",", &save)) {
                if (rule->private_count >= MAX_PRIVATE) return false;
                private_address_t *private_address = &rule->private_addresses[rule->private_count];
                memset(private_address, 0, sizeof(*private_address));
                if (inet_pton(AF_INET, item, &private_address->address.ipv4) == 1) {
                    private_address->family = AF_INET;
                } else if (inet_pton(AF_INET6, item, &private_address->address.ipv6) == 1) {
                    private_address->family = AF_INET6;
                } else {
                    return false;
                }
                rule->private_count += 1;
            }
        }
        index += 4;
    }
    return true;
}

int main(int argc, char **argv) {
    if (argc < 4) {
        fprintf(stderr, "usage: %s --gateway --socket PATH [--rule HOST PORT PRIVATE,...]\n", argv[0]);
        fprintf(stderr, "       %s --bridge --socket PATH -- COMMAND [ARGS...]\n", argv[0]);
        return 2;
    }
    if (strcmp(argv[1], "--gateway") == 0) {
        if (strcmp(argv[2], "--socket") != 0) return 2;
        policy_t policy;
        if (!parse_policy(argc, argv, 4, &policy)) return 2;
        return run_gateway(argv[3], &policy);
    }
    if (strcmp(argv[1], "--bridge") == 0) {
        if (strcmp(argv[2], "--socket") != 0 || argc < 6 || strcmp(argv[4], "--") != 0) return 2;
        return run_bridge(argv[3], &argv[5]);
    }
    return 2;
}
