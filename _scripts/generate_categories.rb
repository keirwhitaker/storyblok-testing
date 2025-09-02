#!/usr/bin/env ruby
# frozen_string_literal: true

require "json"
require "yaml"
require "fileutils"

DATA_FILE      = "_data/listings.json"
CATEGORIES_DIR = "categories"

abort "Missing #{DATA_FILE}, run fetch first!" unless File.exist?(DATA_FILE)

listings = JSON.parse(File.read(DATA_FILE))

FileUtils.rm_rf(CATEGORIES_DIR)
FileUtils.mkdir_p(CATEGORIES_DIR)

grouped = listings.group_by { |it| it["category"] }

grouped.each do |category, entries|
  cat_slug = category.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
  cat_dir  = File.join(CATEGORIES_DIR, cat_slug)
  FileUtils.mkdir_p(cat_dir)

  # Category index page
index_front_matter = {
  "layout"    => "category",
  "title"     => category.capitalize,
  "category"  => category,
  "slug"      => cat_slug,
  "permalink" => "/categories/#{cat_slug}/"
}


  index_content = +"---\n"
  index_content << index_front_matter.to_yaml.sub(/\A---\s*\n/, "")
  index_content << "---\n\n"
  index_content << "{% assign entries = site.entries | where: \"category\", \"#{category}\" %}\n"
  index_content << "{% for entry in entries %}\n"
  index_content << "- [{{ entry.title }}]({{ entry.url }})\n"
  index_content << "{% endfor %}\n"

  File.write(File.join(cat_dir, "index.md"), index_content)

  # Duplicate entries under the category folder
  entries.each do |it|
    slug = it["slug"] || it["title"].downcase.gsub(/[^a-z0-9]+/, "-")

    fm = {
      "layout"    => "entry",
      "title"     => it["title"],
      "slug"      => slug,
      "category"  => category,
      "permalink" => "/categories/#{cat_slug}/#{slug}/"
    }

    body = it["description"].to_s

    file_content = +"---\n"
    file_content << fm.to_yaml.sub(/\A---\s*\n/, "")
    file_content << "---\n\n"
    file_content << body

    File.write(File.join(cat_dir, "#{slug}.md"), file_content)
  end
end

puts "Generated #{grouped.size} category folders in #{CATEGORIES_DIR}/"

# Master categories index
index_front_matter = {
  "layout"    => "categories",
  "title"     => "All Categories",
  "permalink" => "/categories/"
}

index_content = +"---\n"
index_content << index_front_matter.to_yaml.sub(/\A---\s*\n/, "")
index_content << "---\n\n"
index_content << "<ul>\n"
grouped.keys.sort.each do |cat|
  slug = cat.to_s.downcase.gsub(/[^a-z0-9]+/, "-")
  index_content << "  <li><a href=\"/categories/#{slug}/\">#{cat}</a></li>\n"
end
index_content << "</ul>\n"

File.write(File.join(CATEGORIES_DIR, "index.md"), index_content)

puts "Generated master categories index at /categories/"
