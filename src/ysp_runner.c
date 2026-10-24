/* Tiny loopback HTTP host for the LuaJIT ysp-live adapter. */
#include <arpa/inet.h>
#include <errno.h>
#include <lua.h>
#include <lauxlib.h>
#include <lualib.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static volatile sig_atomic_t running = 1;
static int listen_fd = -1;
static void stop_server(int sig) { (void)sig; running = 0; if (listen_fd >= 0) close(listen_fd); listen_fd = -1; }

static void serve(lua_State *L, int fd) {
    char request[8192], path[512], header[512];
    ssize_t n = recv(fd, request, sizeof(request) - 1, 0);
    if (n <= 0) return;
    request[n] = 0;
    if (sscanf(request, "GET %511s", path) != 1) return;
    char *query = strchr(path, '?');
    if (query) *query = 0;

    lua_getglobal(L, "handle_request");
    lua_pushstring(L, path);
    int status = 503;
    const char *type = "text/plain; charset=utf-8";
    const char *body = "service error\n";
    size_t length = strlen(body);
    if (lua_pcall(L, 1, 3, 0) == 0) {
        status = (int)lua_tointeger(L, -3);
        type = lua_tostring(L, -2);
        body = lua_tolstring(L, -1, &length);
        if (!body || !type) { body = "service error\n"; length = strlen(body); type = "text/plain; charset=utf-8"; status = 503; }
    } else {
        fprintf(stderr, "ysp service: %s\n", lua_tostring(L, -1));
        lua_pop(L, 1);
        lua_pushnil(L); lua_pushnil(L); lua_pushnil(L);
    }
    if (status < 100 || status > 599) status = 503;
    int hn = snprintf(header, sizeof(header), "HTTP/1.1 %d %s\r\nContent-Type: %s\r\nContent-Length: %zu\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n",
                      status, status == 200 ? "OK" : status == 404 ? "Not Found" : "Unavailable", type, length);
    if (hn > 0) send(fd, header, (size_t)hn, MSG_NOSIGNAL);
    while (length) {
        ssize_t sent = send(fd, body, length, MSG_NOSIGNAL);
        if (sent <= 0) break;
        body += sent;
        length -= (size_t)sent;
    }
    lua_pop(L, 3);
}

int main(int argc, char **argv) {
    if (argc < 2) { fprintf(stderr, "usage: ysp_runner script [port]\n"); return 2; }
    int port = argc > 2 ? atoi(argv[2]) : 18766;
    if (port < 1 || port > 65535) return 2;
    signal(SIGINT, stop_server);
    signal(SIGTERM, stop_server);
    signal(SIGPIPE, SIG_IGN);
    lua_State *L = luaL_newstate();
    if (!L) return 2;
    luaL_openlibs(L);
    if (luaL_dofile(L, argv[1]) != 0) {
        fprintf(stderr, "ysp service load: %s\n", lua_tostring(L, -1));
        lua_close(L);
        return 2;
    }
    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) return 2;
    listen_fd = server;
    int yes = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons((unsigned short)port);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(server, (struct sockaddr *)&addr, sizeof(addr)) || listen(server, 8)) {
        perror("ysp service bind"); close(server); lua_close(L); return 2;
    }
    fprintf(stderr, "ysp service listening on 127.0.0.1:%d\n", port);
    while (running) {
        int client = accept(server, NULL, NULL);
        if (client < 0) { if (errno == EINTR) continue; break; }
        struct timeval timeout = {45, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
        serve(L, client);
        close(client);
    }
    if (listen_fd >= 0) close(server);
    lua_close(L);
    return 0;
}
