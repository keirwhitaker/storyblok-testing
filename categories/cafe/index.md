---
layout: category
title: Cafe
category: cafe
slug: cafe
permalink: "/categories/cafe/"
---

{% assign entries = site.entries | where: "category", "cafe" %}
{% for entry in entries %}
- [{{ entry.title }}]({{ entry.url }})
{% endfor %}
