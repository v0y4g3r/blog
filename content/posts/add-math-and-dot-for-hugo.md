---
title: "Add MathJax and Graphviz support for HUGO"
date: 2020-04-12T14:22:22+08:00
draft: true
toc: false
images:
tags: 
  - hugo
---

1. Get into your theme folder

2. Find some directory named `layouts/posts/single.html`

3. Inside the `{{ define main }}` block, paste following snippets

```js
{{ if .Params.viz }}
  <script type="text/javascript" src="https://cdn.bootcss.com/viz.js/1.8.2/viz.js"> </script>
  <script type="text/javascript">
  (function(){
    var vizPrefix = "language-viz-";
    Array.prototype.forEach.call(document.querySelectorAll("[class^=" + vizPrefix + "]"), function(x){
      var engine;
      x.getAttribute("class").split(" ").forEach(function(cls){
        if (cls.startsWith(vizPrefix)) {
          engine = cls.substr(vizPrefix.length);
        }
      });
      var image = new DOMParser().parseFromString(Viz(x.innerText, {format:"svg", engine:engine}), "image/svg+xml");
      x.parentNode.insertBefore(image.documentElement, x);
      x.style.display = 'none'
      x.parentNode.style.backgroundColor = "white"
    });
  })();
  </script>
{{ end }}

{{ if  .Params.math   }}
  <script type="text/javascript">
    window.MathJax = {
      tex2jax: {
        inlineMath: [['$','$'], ['\\(','\\)']],
        displayMath: [['$$','$$'], ['\[','\]']],
        processEscapes: true,
        processEnvironments: true,
        skipTags: ['script', 'noscript', 'style', 'textarea', 'pre'],
        TeX: { equationNumbers: { autoNumber: "AMS" },
          extensions: ["AMSmath.js", "AMSsymbols.js", "color.js"] }
      },
      AuthorInit: function () {
        MathJax.Hub.Register.StartupHook("Begin",function () {
          MathJax.Hub.Queue(function() {
            var all = MathJax.Hub.getAllJax(), i;
            for(i = 0; i < all.length; i += 1) {
              all[i].SourceElement().parentNode.className += ' has-jax';
            }
          })
        });
      }
    };
  </script>
  <script  type="text/javascript"
    src="https://cdn.bootcss.com/mathjax/2.7.7/MathJax.js?config=TeX-MML-AM_CHTML">
  </script>
{{ end }}
```

4. Create some posts and add following config inside front-matter
```
viz: true
math: true
```
And try some graphviz and mathjax stuff!

![mathjax-dot-demo](/images/mathjax-dot-demo.png)

> You may check the demo [here](/posts/math-and-dot-demo)