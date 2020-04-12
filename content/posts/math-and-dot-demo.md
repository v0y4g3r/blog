---
title: "Graphviz and mathjax demo"
date: 2020-04-11T23:26:41+08:00
draft: true
viz: true
math: true
---

```viz-dot
digraph g{
    rankdir=LR;
    node [shape=record,width=01,height=.1];
	a[label="<1>Hash Table|<2>Node|<3>Node|...|<4>TreeNode"];
    {
        // graph[rankdir=LR]    
        node1[label="{<1>A1|<2>A2|...|An}"]
        node2[label="{<1>B1|<2>B2|...|Bn}"]
        // node3[label="{<1>C1|<2>C2}"]
        subgraph cluster_treenode{
            penwidth=0;
            node[shape=circle];
            root[label="", style=filled,fillcolor=black,width=.2];
            n1[label="", style=filled,fillcolor=red,width=.2]
            n2[label="", style=filled,fillcolor=black,width=.2]
            n3[label="", style=filled,fillcolor=black,width=.2]
            n4[label="", style=filled,fillcolor=red,width=.2]
            n5[label="", style=filled,fillcolor=black,width=.2]
            n6[label="", style=filled,fillcolor=black,width=.2]
            root->n1;
            n1->n2;
            n1->n3;
            root->n4;
            n4->n5;
            n4->n6;
        }
    }
    
    a:2:e->node1:1 [style=dashed];
    a:3:e->node2:1;    
    a:4:e->root;    

    // node3:d->node3:sa2;
}
```

$$f(a) = \frac{1}{2\pi i} \oint\frac{f(z)}{z-a}dz$$
