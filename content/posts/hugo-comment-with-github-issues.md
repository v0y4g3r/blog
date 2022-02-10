---
title: "使用 GitHub Issue 作为 Hugo 的评论系统"
date: 2022-02-10T15:07:10+08:00
draft: true
toc: false
issueNumber: 3
images:
tags: 
  - Hugo
  - Github
---

# 安装 Octomments
按照 [Octomments](https://ocs.vercel.app/) 的介绍，将 Octomments 安装到您的 GitHub 账户，确保它拥有访问您的目标 repo 的 issue 的权限。

# 配置 GitHub issue
在配置文件中增加配置项：
- `comment.owner`：Issue repo 的拥有者
- `comment.repo`：Issue repo 的名字

# 配置 Comment 组件

在您的博客站点根目录下的`layouts/partials/comments.html` 模板中增加：

```html
{{ if .Params.issueNumber -}}
<link href="https://unpkg.com/octomments/build/ocs-ui.min.css" rel="stylesheet">
<div id="comments"></div>
<script src="https://unpkg.com/octomments/build/ocs.min.js"></script>

<script>
  Octomments({
    github: {
      owner: '{{ $.Site.Params.comment.owner }}',
      repo: '{{ $.Site.Params.comment.repo }}',
    },
    issueNumber: {{ .Params.issueNumber }},
    renderer: [OctommentsRenderer, '#comments']
  }).init();
</script>

{{ end }}
```

# 配置需要评论的文章
在文章的 metadata 章节加入创建的 issue 的 issue number，如本文的 metadata：
```yaml
---
title: "使用 GitHub Issue 作为 Hugo 的评论系统"
date: 2022-02-10T15:07:10+08:00
draft: true
toc: false
issueNumber: 3
images:
tags: 
  - Hugo
  - Github
---
```

这样本文的末尾就会出现一个评论栏啦，所有对本文的评论都会同步到 GitHub 的 issue 中。





