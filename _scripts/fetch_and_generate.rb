#!/usr/bin/env ruby
require "net/http"
require "json"
require "fileutils"
require "yaml"
require "digest"

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
    slug = "place-#{story["id"]}" if slug.empty? # final fallback
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
    tags = (story["tag_list"] || []).map { |t| { "name" => t, "slug" => slugify(t) } }
    gallery = (content["gallery"] || []).map { |g| g["filename"] }
    short = generate_short_code(slug)

    front_matter = {
      "layout" => "place",
      "title" => title,
      "slug" => slug,
      "canonical_url" => "/places/#{slug}/",
      "canonical" => "/places/#{slug}/",
      "tags" => tags,
      "neighbourhood" => content["neighbourhood"],
      "address" => content["address"],
      "gallery" => gallery,
      "website" => content.dig("website", "url"),
      "instagram" => content.dig("instagram", "url"),
      "latitude" => content["latitude"],
      "longitude" => content["longitude"],
      "description" => content["description"],
      "editors_note" => content["editors_note"],
      "short_description" => content["short_description"],
      "price" => content["Price"], # 👈 Price field
      "permalink" => "/places/#{slug}/",
      "short_code" => short,
      "short_link" => "/go/#{short}"
    }

    File.write(File.join(PLACES_DIR, "#{slug}.md"), front_matter.to_yaml + "---\n")
  end
  puts "✅ Wrote #{stories.size} canonical places"
end

# --- Write Tag Indexes & Tagged Pages ---
def write_tagged_pages(stories)
  FileUtils.rm_rf(DIRECTORY_DIR)
  FileUtils.mkdir_p(DIRECTORY_DIR)

  # Build master tag list with display + slug
  all_tags = stories.flat_map { |s| s["tag_list"] || [] }
  tags = all_tags.uniq.map { |t| { "name" => t, "slug" => slugify(t) } }.sort_by { |t| t["slug"] }

  # Master index
  master_front = { "layout" => "tags", "title" => "Directory", "permalink" => "/directory/" }
  File.write(File.join(DIRECTORY_DIR, "index.md"), master_front.to_yaml + "---\n")

  # Per tag index + entry pages
  tags.each do |tag|
    tag_dir = File.join(DIRECTORY_DIR, tag["slug"])
    FileUtils.mkdir_p(tag_dir)

    # Tag index
    tag_front = { "layout" => "tag", "title" => tag["name"], "tag" => tag, "permalink" => "/directory/#{tag["slug"]}/" }
    File.write(File.join(tag_dir, "index.md"), tag_front.to_yaml + "---\n")

    # Per-place pages under this tag
    stories.each do |story|
      next unless (story["tag_list"] || []).include?(tag["name"])

      slug = safe_slug(story)
      content = story["content"] || {}
      title = content["title"] || story["name"]
      tags_full = (story["tag_list"] || []).map { |t| { "name" => t, "slug" => slugify(t) } }
      gallery = (content["gallery"] || []).map { |g| g["filename"] }
      short = generate_short_code(slug)

      front_matter = {
        "layout" => "place",
        "title" => title,
        "slug" => slug,
        "canonical_url" => "/places/#{slug}/",
        "canonical" => "/places/#{slug}/",
        "tags" => tags_full,
        "neighbourhood" => content["neighbourhood"],
        "address" => content["address"],
        "gallery" => gallery,
        "website" => content.dig("website", "url"),
        "instagram" => content.dig("instagram", "url"),
        "latitude" => content["latitude"],
        "longitude" => content["longitude"],
        "description" => content["description"],
        "editors_note" => content["editors_note"],
        "short_description" => content["short_description"],
        "price" => content["Price"], # 👈 Price field
        "permalink" => "/directory/#{tag["slug"]}/#{slug}/",
        "short_code" => short,
        "short_link" => "/go/#{short}"
      }

      File.write(File.join(tag_dir, "#{slug}.md"), front_matter.to_yaml + "---\n")
    end
  end
  puts "✅ Wrote #{tags.size} tag indexes and full entry pages under /directory/"
end

# --- Write Redirects ---
def write_redirects(stories)
  File.open(REDIRECTS_FILE, "w") do |f|
    # /go root -> directory
    f.puts "/go/   /directory/   301"

    stories.each do |story|
      slug = safe_slug(story)
      short = generate_short_code(slug)
      target = "/places/#{slug}/"

      f.puts "/go/#{short}   #{target}   301"
    end
  end
  puts "✅ Wrote shortlink redirects to #{REDIRECTS_FILE}"
end

# --- Write JSON Export (private + public) ---
def write_json(stories)
  entries =
    stories.map do |story|
      content = story["content"] || {}
      slug = safe_slug(story)
      canonical = "/places/#{slug}/"
      short = generate_short_code(slug)
      shortlink = "/go/#{short}"

      {
        title: content["title"] || story["name"],
        slug: slug,
        canonical_url: canonical,
        canonical: canonical,
        tags: (story["tag_list"] || []).map { |t| { "name" => t, "slug" => slugify(t) } },
        neighbourhood: content["neighbourhood"],
        address: content["address"],
        gallery: (content["gallery"] || []).map { |g| g["filename"] },
        website: content.dig("website", "url"),
        instagram: content.dig("instagram", "url"),
        latitude: content["latitude"],
        longitude: content["longitude"],
        description: content["description"],
        editors_note: content["editors_note"],
        short_description: content["short_description"],
        price: content["Price"], # 👈 Price field
        permalink: canonical,
        short_code: short,
        short_link: shortlink
      }
    end

  # Private Jekyll data
  data_dir = File.join(__dir__, "..", "_data")
  FileUtils.mkdir_p(data_dir)
  File.write(File.join(data_dir, "places.json"), JSON.pretty_generate(entries))

  # Public JSON for frontend use
  api_dir = File.join(__dir__, "..", "api")
  FileUtils.mkdir_p(api_dir)
  File.write(File.join(api_dir, "places.json"), JSON.pretty_generate(entries))

  puts "✅ Wrote JSON data to _data/places.json and api/places.json"
end

# --- Run ---
stories = fetch_all_stories
write_places(stories)
write_tagged_pages(stories)
write_redirects(stories)
write_json(stories)
