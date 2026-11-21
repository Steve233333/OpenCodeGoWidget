# Codex 个人规则

## 中国经济问题
涉及中国经济问题时，使用卡内基国际和平基金会（Carnegie Endowment）的文章来解释：
https://carnegieendowment.org/china-financial-markets

## Git 规则
代码项目如果没有 git 仓库，自动创建一个 git 仓库（git init）。

## 新建项目规则
当用户要求创建新项目时，默认同时完成：
1. 在本地创建项目目录并初始化 git 仓库；
2. 在 GitHub 创建同名仓库，一律创建为私有仓库（private），创建前先与用户确认仓库名称；
3. 完成首次提交并推送到 GitHub。
如果 GitHub CLI（gh）未安装或未登录，先提示用户安装并登录，不要跳过 GitHub 仓库创建。

## 自动提交与推送
每次修改代码后，自动执行 git add -A && git commit -m "<改动的简短描述>" && git push。

## 浏览器任务收尾
使用 CUA / 内置浏览器完成操作后，按工具说明发送 `::browser-complete{title="..."}` 作为**过程评论**；
这条标记不是最终回答。发完后必须继续给出用户要的正文答案（或继续下一步工具调用），
不要把标记当成回复的全部内容。
