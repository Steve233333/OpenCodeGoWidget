#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

/* 2026-10-07：除了 --user-data-dir，再强制中文界面。
   起因：Codex 更新后「不联网打开会自动退回英文」—— 语言是联网时从账号取的，
   离线时只能用 Chromium 默认 locale。这里在启动参数里把 zh-CN 钉死。 */
int main(int argc, char **argv) {
    char *home = getenv("HOME");
    if (!home) home = "";
    char ud[1100];
    char bin[1100];
    snprintf(ud, sizeof(ud), "--user-data-dir=%s/Library/Application Support/Codex-Patched", home);
    snprintf(bin, sizeof(bin), "%s/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin", home);
    int n = argc + 3;
    char **newargv = malloc(sizeof(char*) * (n + 1));
    newargv[0] = bin;
    newargv[1] = ud;
    newargv[2] = "--lang=zh-CN";
    newargv[3] = "--accept-lang=zh-CN,zh;q=0.9";
    for (int i = 1; i < argc; i++) newargv[i + 3] = argv[i];
    newargv[n] = NULL;
    execv(bin, newargv);
    perror("execv");
    return 1;
}
