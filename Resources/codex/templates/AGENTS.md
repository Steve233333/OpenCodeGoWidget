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
