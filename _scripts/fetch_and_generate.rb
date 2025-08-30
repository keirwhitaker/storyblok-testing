#!/usr/bin/env ruby
# frozen_string_literal: true
require "yaml"
require "json"
require "net/http"
require "uri"
require "fileutils"

# Replace the URL with your actual one
URL = ARGV[0] || "https://api.storyblok.com/v2/cdn/stories?content_type=directory-listing&cv=1756476116&page=100&per_page=1&token=7g1HChyR3HjBieTwCFeqBQtt&version=published"

# Paths
DATA_FILE = "_data/listings.json"
OUT_DIR   = "_entries"

def fetch_json
  all = []
  page = 1
  per_page = 100

  loop do
    url = "#{URL}&page=#{page}&per_page=#{per_page}"
    uri = URI(url)
    res = Net::HTTP.get_response(uri)

    # follow redirects if needed
    limit = 5
    while res.is_a?(Net::HTTPRedirection) && limit > 0
      uri = URI(res["location"])
      res = Net::HTTP.get_response(uri)
      limit -= 1
    end

    unless res.is_a?(Net::HTTPSuccess)
      abort "Failed to fetch: #{res.code} #{res.body}"
    end

    body = JSON.parse(res.body)
    stories = body["stories"] || []
    all.concat(stories)
    puts "Fetched page #{page}, #{stories.size} stories"

    break if stories.empty? || stories.size < per_page
    page += 1
  end

  { "stories" => all }
end



def simplify(json)
  json.fetch("stories", []).map do |s|
    c = s["content"] || {}
    {
      "slug"       => s["slug"],
      "title"      => c["title"] || s["name"],
      "description"=> c["description"] || "",
      "category"   => c["category"],
      "address"    => c["address"],
      "website"    => c.dig("website", "url"),
      "instagram"  => c.dig("instagram", "url"),
      "image"      => c.dig("image", "filename"),
      "gallery"    => (c["gallery"] || []).map { |g| g["filename"] },
      "tags"       => s["tag_list"],
      "latitude"   => c["latitude"],
      "longitude"  => c["longitude"],
      "date"       => s["first_published_at"] || s["created_at"]
    }
  end
end

def write_json(array)
  FileUtils.mkdir_p(File.dirname(DATA_FILE))
  File.write(DATA_FILE, JSON.pretty_generate(array))
  puts "Wrote #{array.size} items to #{DATA_FILE}"
end

def write_posts(items)
  FileUtils.rm_rf(OUT_DIR)
  FileUtils.mkdir_p(OUT_DIR)
  items.each do |it|
    slug = it["slug"] || it["title"].downcase.gsub(/[^a-z0-9]+/, "-")
    fm = {
      "layout"     => "entry",
      "title"      => it["title"],
      "slug"       => slug,
      "category"   => it["category"],
      "address"    => it["address"],
      "website"    => it["website"],
      "instagram"  => it["instagram"],
      "image"      => it["image"],
      "gallery"    => it["gallery"],
      "tags"       => it["tags"],
      "latitude"   => it["latitude"],
      "longitude"  => it["longitude"],
      "date"       => it["date"],
      "permalink"  => "/entries/#{slug}/"
    }

    body = it["description"]

    content = +"---\n"
    content << fm.to_yaml.sub(/\A---\s*\n/, "")
    content << "---\n\n"
    content << body

    File.write(File.join(OUT_DIR, "#{slug}.md"), content)
  end
  puts "Generated #{items.size} posts to #{OUT_DIR}"
end

# Run
data = fetch_json
listings = simplify(data)
write_json(listings)
write_posts(listings)
