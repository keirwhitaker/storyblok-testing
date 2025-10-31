#!/usr/bin/env ruby
require "net/http"
require "json"
require "fileutils"
require "yaml"
require "digest"
require "date"

# --- Config ---
CONFIG_FILE = "_config.storyblok.yaml"
local_config = (File.exist?(CONFIG_FILE) ? YAML.load_file(CONFIG_FILE)["storyblok"] || {} : {})

TOKEN = ENV["STORYBLOK_TOKEN"] || local_config["token"] || abort("Missing STORYBLOK_TOKEN")
VERSION = ENV["STORYBLOK_VERSION"] || local_config["version"] || "published"
CTYPE = ENV["STORYBLOK_CONTENT_TYPE"] || local_config["content_type"] || "directory-listing"

API_URL = "https://api.storyblok.com/v2/cdn/stories"
PLACES_DIR = File.join(__dir__, "..", "_places")
DIRECTORY_DIR = File.join(__dir__, "..", "directory")
REDIRECTS_FILE = File.join(__dir__, "..", "_redirects")
TAG_GROUPS_FILE = File.join(__dir__, "..", "_data", "tag_groups.json")
TAG_GROUPS = File.exist?(TAG_GROUPS_FILE) ? JSON.parse(File.read(TAG_GROUPS_FILE)) : {}

# --- Helpers ---
def slugify(str)
  return "" if str.nil?
  str.downcase.strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

def safe_slug(story)
  slug = story["slug"]
  if slug.nil? || slug.strip.empty?
    name = story["name"] || "untitled"
    slug = slugify(name)
    slug = "place-#{story["id"]}" if slug.empty?
  end
  slug
end

def generate_short_code(slug)
  Digest::MD5.hexdigest(slug)[0..5]
end

def fetch_with_redirect(uri, limit = 5)
  raise "Too many redirects" if limit == 0
  res = Net::HTTP.get_response(uri)
  case res
  when Net::HTTPSuccess
    res
  when Net::HTTPRedirection
    new_uri = URI(res["location"])
    fetch_with_redirect(new_uri, limit - 1)
  else
    res.error!
  end
end

def format_date(str)
  return nil if str.nil? || str.empty?
  begin
    Date.parse(str)
  rescue StandardError
    nil
  end
end

def format_date_with_ts(str)
  return nil, nil if str.nil? || str.empty?
  date =
    begin
      Date.parse(str)
    rescue StandardError
      nil
    end
  return nil, nil unless date
  iso = date.strftime("%Y-%m-%d")
  ts = date.to_time.to_i
  [iso, ts]
end

def parse_tag(tag)
  if tag =~ /^(\d+)-(.*)$/
    group = $1.to_i
    base = $2
  else
    group = nil
    base = tag
  end

  group_name = TAG_GROUPS[group.to_s]
  warn "⚠️  Tag '#{tag}' has group #{group}, but no mapping found in tag_groups.json" if group && group_name.nil?

  { "name" => base.split.map(&:capitalize).join(" "), "slug" => slugify(base), "group" => group, "group_name" => group_name }
end

def parse_neighbourhood(value)
  return nil if value.nil? || value.strip.empty?
  { "name" => value.split.map(&:capitalize).join(" "), "slug" => slugify(value) }
end

# --- Fetch Stories ---
def fetch_all_stories
  page = 1
  stories = []

  loop do
    uri = URI("#{API_URL}?content_type=#{CTYPE}&page=#{page}&per_page=100&token=#{TOKEN}&version=#{VERSION}")
    res = fetch_with_redirect(uri)
    data = JSON.parse(res.body)

    stories.concat(data["stories"])

    total = res["total"].to_i
    break if stories.size >= total
    page += 1
  end

  stories
end

# --- Write Places (canonical) ---
def write_places(stories)
  FileUtils.rm_rf(PLACES_DIR)
  FileUtils.mkdir_p(PLACES_DIR)

  stories.each do |story|
    slug = safe_slug(story)
    content = story["content"] || {}
    title = content["title"] || story["name"]
    tags = (story["tag_list"] || []).map { |t| parse_tag(t) }
    gallery = (content["gallery"] || []).map { |g| g["filename"] }
    short = generate_short_code(slug)

    front_matter = { "layout" => "place", "title" => title, "slug" => slug, "created_at" => format_date(story["created_at"]), "published_at" => format_date(story["published_at"]), "updated_at" => format_date(story["updated_at"]), "permalink" => "/places/#{slug}/", "canonical_url" => "/places/#{slug}/", "short_link" => { "code" => short, "url" => "/go/#{short}" }, "tags" => tags, "neighbourhood" => parse_neighbourhood(content["neighbourhood"]), "address" => content["address"], "gallery" => gallery, "website" => content.dig("website", "url"), "instagram" => content.dig("instagram", "url"), "latitude" => content["latitude"], "longitude" => content["longitude"], "description" => content["description"], "editors_note" => content["editors_note"], "short_description" => content["short_description"], "price" => content["Price"] }

    File.write(File.join(PLACES_DIR, "#{slug}.md"), front_matter.to_yaml + "---\n")
  end
  puts "✅ Wrote #{stories.size} canonical places"
end

# --- Write Tag Indexes & Tagged Pages ---
def write_tagged_pages(stories)
  FileUtils.rm_rf(DIRECTORY_DIR)
  FileUtils.mkdir_p(DIRECTORY_DIR)

  raw_tags = stories.flat_map { |s| s["tag_list"] || [] }
  tags = raw_tags.uniq.map { |t| parse_tag(t) }.sort_by { |t| t["slug"] }

  master_front = { "layout" => "tags", "title" => "Directory", "permalink" => "/directory/" }
  File.write(File.join(DIRECTORY_DIR, "index.md"), master_front.to_yaml + "---\n")

  tags.each do |tag|
    tag_dir = File.join(DIRECTORY_DIR, tag["slug"])
    FileUtils.mkdir_p(tag_dir)

    tag_front = { "layout" => "tag", "title" => tag["name"], "tag" => tag, "permalink" => "/directory/#{tag["slug"]}/", "canonical_url" => "/directory/#{tag["slug"]}/" }
    File.write(File.join(tag_dir, "index.md"), tag_front.to_yaml + "---\n")

    stories.each do |story|
      next unless (story["tag_list"] || []).any? { |t| parse_tag(t)["slug"] == tag["slug"] }

      slug = safe_slug(story)
      content = story["content"] || {}
      title = content["title"] || story["name"]
      tags_full = (story["tag_list"] || []).map { |t| parse_tag(t) }
      gallery = (content["gallery"] || []).map { |g| g["filename"] }
      short = generate_short_code(slug)

      front_matter = { "layout" => "place", "title" => title, "slug" => slug, "created_at" => format_date(story["created_at"]), "published_at" => format_date(story["published_at"]), "updated_at" => format_date(story["updated_at"]), "permalink" => "/directory/#{tag["slug"]}/#{slug}/", "canonical_url" => "/places/#{slug}/", "short_link" => { "code" => short, "url" => "/go/#{short}" }, "tags" => tags_full, "neighbourhood" => parse_neighbourhood(content["neighbourhood"]), "address" => content["address"], "gallery" => gallery, "website" => content.dig("website", "url"), "instagram" => content.dig("instagram", "url"), "latitude" => content["latitude"], "longitude" => content["longitude"], "description" => content["description"], "editors_note" => content["editors_note"], "short_description" => content["short_description"], "price" => content["Price"] }

      File.write(File.join(tag_dir, "#{slug}.md"), front_matter.to_yaml + "---\n")
    end
  end
  puts "✅ Wrote #{tags.size} tag indexes and entry stubs"
end

# --- Write Redirects ---
def write_redirects(stories)
  File.open(REDIRECTS_FILE, "w") do |f|
    f.puts "/go/   /directory/   301"
    stories.each do |story|
      slug = safe_slug(story)
      short = generate_short_code(slug)
      f.puts "/go/#{short}   /places/#{slug}/   301"
    end
  end
  puts "✅ Wrote shortlink redirects to #{REDIRECTS_FILE}"
end

# --- Write Places JSON (private + public) ---
def write_json(stories)
  entries =
    stories.map do |story|
      content = story["content"] || {}
      slug = safe_slug(story)
      canonical = "/places/#{slug}/"
      short = generate_short_code(slug)

      created_iso, created_ts = format_date_with_ts(story["created_at"])
      published_iso, published_ts = format_date_with_ts(story["published_at"])
      updated_iso, updated_ts = format_date_with_ts(story["updated_at"])

      { title: content["title"] || story["name"], slug: slug, created_at: created_iso, created_at_ts: created_ts, published_at: published_iso, published_at_ts: published_ts, updated_at: updated_iso, updated_at_ts: updated_ts, canonical_url: canonical, short_link: { code: short, url: "/go/#{short}" }, tags: (story["tag_list"] || []).map { |t| parse_tag(t) }, neighbourhood: parse_neighbourhood(content["neighbourhood"]), address: content["address"], gallery: (content["gallery"] || []).map { |g| g["filename"] }, website: content.dig("website", "url"), instagram: content.dig("instagram", "url"), latitude: content["latitude"], longitude: content["longitude"], description: content["description"], editors_note: content["editors_note"], short_description: content["short_description"], price: content["Price"] }
    end

  data_dir = File.join(__dir__, "..", "_data")
  api_dir = File.join(__dir__, "..", "api")
  [data_dir, api_dir].each { |d| FileUtils.mkdir_p(d) }

  File.write(File.join(data_dir, "places.json"), JSON.pretty_generate(entries))
  File.write(File.join(api_dir, "places.json"), JSON.pretty_generate(entries))

  puts "✅ Wrote places.json to _data/ and /api/"
end

# --- Write Tags JSON ---
def write_tags_json(stories)
  tag_counts =
    Hash.new do |h, k|
      parsed = parse_tag(k)
      h[k] = { "name" => parsed["name"], "slug" => parsed["slug"], "group" => parsed["group"], "group_name" => parsed["group_name"], "count" => 0, "places" => [], "canonical_url" => "/directory/#{parsed["slug"]}/" }
    end

  stories.each do |story|
    slug = safe_slug(story)
    (story["tag_list"] || []).each do |t|
      tag_counts[t]["count"] += 1
      tag_counts[t]["places"] << slug unless tag_counts[t]["places"].include?(slug)
    end
  end

  # sort by group first, then alphabetically by name
  tags_array = tag_counts.values.sort_by { |t| [t["group"] || 999, t["name"]] }

  data_dir = File.join(__dir__, "..", "_data")
  FileUtils.mkdir_p(data_dir)
  File.write(File.join(data_dir, "tags.json"), JSON.pretty_generate(tags_array))

  total_tags = tags_array.size
  groups = tags_array.map { |t| t["group"] }.compact.uniq.size
  unmapped = tags_array.count { |t| t["group"].nil? || t["group_name"].nil? }

  puts "✅ Wrote tags.json with #{total_tags} tags (groups: #{groups}, unmapped: #{unmapped})"
end

# --- Run ---
stories = fetch_all_stories
write_places(stories)
write_tagged_pages(stories)
write_redirects(stories)
write_json(stories)
write_tags_json(stories)
puts "🎉 All done!"
