/* Mach-O 启动器：给 ChatGPT-Patched.app 注入 --user-data-dir，隔离副本的配置目录。
 *
 * 由来：patch.sh 会把副本的 Contents/MacOS/ChatGPT 挪成 ChatGPT.bin，然后放一个
 * 同名小可执行文件在这里，用它 execv 真正的二进制并塞进：
 *   --user-data-dir=$HOME/Library/Application Support/Codex-Patched
 * （launchd 不接受 shell 脚本当主可执行文件；CHROME_USER_DATA_DIR 会被 Electron 忽略；
 *   空格分隔的 --user-data-dir 参数不会传给子进程 —— 所以必须用 '=' 形式。）
 *
 * 这份源码与 patch.sh 内嵌的 heredoc 保持一字不差。
 * 预编译产物：resources/patch/launcher-universal（arm64 + x86_64），
 * 供没装 Xcode 命令行工具（没有 clang）的机器直接使用。
 * 重新生成：
 *   clang -O2 -arch arm64 -arch x86_64 -o launcher-universal launcher.c
 */
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>

int main(int argc, char **argv) {
    char *home = getenv("HOME");
    if (!home) home = "";
    char ud[1100];
    char bin[1100];
    snprintf(ud, sizeof(ud), "--user-data-dir=%s/Library/Application Support/Codex-Patched", home);
    snprintf(bin, sizeof(bin), "%s/Applications/ChatGPT-Patched.app/Contents/MacOS/ChatGPT.bin", home);
    int n = argc + 1;
    char **newargv = malloc(sizeof(char*) * (n + 1));
    newargv[0] = bin;
    newargv[1] = ud;
    for (int i = 1; i < argc; i++) newargv[i + 1] = argv[i];
    newargv[n] = NULL;
    execv(bin, newargv);
    perror("execv");
    return 1;
}
