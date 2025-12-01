#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8

require "dotenv"
Dotenv.load
require "net/http"
require "json"
require "uri"
require "fileutils"
require "time"
require "stringio"
require "base64"
require "yaml"
require "cloudinary"
require "cloudinary/uploader"
require "cloudinary/api"

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
NOTION_TOKEN = ENV["NOTION_TOKEN"]
DATABASE_ID = ENV["NOTION_DB_ID"]
CLOUDINARY_URL = ENV["CLOUDINARY_URL"]
CACHE_PATH = ".netlify/cache/cloudinary_cache.json"
DRY_RUN = false
NOTION_API_VERSION = "2022-06-28"
NOTION_RATE_LIMIT_DELAY = 0.3
REQUIRED_PROPERTIES = %w[Name Status].freeze

abort "❌ Missing NOTION_TOKEN or NOTION_DB_ID" unless NOTION_TOKEN && DATABASE_ID
abort "❌ Missing CLOUDINARY_URL" unless CLOUDINARY_URL

Cloudinary.config_from_url(CLOUDINARY_URL)

# -------------------------------------------------------------------
# Colour helpers
# -------------------------------------------------------------------
def colour(text, code) = "\e[#{code}m#{text}\e[0m"
def green(t) = colour(t, 32)
def yellow(t) = colour(t, 33)
def red(t) = colour(t, 31)
def cyan(t) = colour(t, 36)

$stats = { created: 0, updated: 0, deleted: 0, skipped: 0, failed_images: 0 }
$failed_images = []

# -------------------------------------------------------------------
# Folder cleanup
# -------------------------------------------------------------------
def clean_folder(path)
  FileUtils.rm_rf(path) if Dir.exist?(path)
  FileUtils.mkdir_p(path)
  puts green("📁 Created fresh #{path} folder.")
end

# We will call:
# - clean_folder("content")
# - clean_folder("_places")
# - clean_folder("_data/taxonomies")
# icons.yml lives in _data/ and is not touched.

# -------------------------------------------------------------------
# Cloudinary cache
# -------------------------------------------------------------------
def fetch_all_cloudinary_assets
  puts yellow("☁️  Rebuilding Cloudinary cache...")
  resources, next_cursor = [], nil
  begin
    loop do
      res = Cloudinary::Api.resources(max_results: 500, next_cursor: next_cursor)
      resources.concat(res["resources"])
      next_cursor = res["next_cursor"]
      break unless next_cursor
    end
  rescue => e
    puts red("⚠️ Cloudinary API error: #{e.message}")
  end
  cache = {}
  resources.each { |r| cache[r["public_id"]] = r["secure_url"] }
  puts green("☁️  Cached #{cache.size} assets.")
  cache
end

def load_cache
  if File.exist?(CACHE_PATH)
    begin
      raw = File.read(CACHE_PATH).strip
      return fetch_all_cloudinary_assets if raw.empty?
      return JSON.parse(raw)
    rescue JSON::ParserError
      puts yellow("⚠️  Invalid cache — rebuilding.")
      return fetch_all_cloudinary_assets
    end
  else
    puts yellow("⚠️  Cache missing — rebuilding.")
    return fetch_all_cloudinary_assets
  end
end

def save_cache(cache)
  FileUtils.mkdir_p(File.dirname(CACHE_PATH))
  File.write(CACHE_PATH, JSON.pretty_generate(cache))
  puts green("💾 Saved Cloudinary cache.")
end

$cache = load_cache

# -------------------------------------------------------------------
# HTTP helpers
# -------------------------------------------------------------------
def notion_request(path, method: :get, body: nil)
  sleep NOTION_RATE_LIMIT_DELAY
  uri = URI("https://api.notion.com/v1/#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{NOTION_TOKEN}"
  req["Notion-Version"] = NOTION_API_VERSION
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }

  raise "Notion error #{res.code}: #{res.body}" unless res.code.to_i == 200
  JSON.parse(res.body)
rescue => e
  puts red("⚠️  Notion request failed: #{e.message}")
  raise
end

# -------------------------------------------------------------------
# Validation
# -------------------------------------------------------------------
def validate_entry(entry)
  missing = REQUIRED_PROPERTIES.reject { |p| entry["properties"].key?(p) }
  if missing.any?
    puts yellow("⚠️ Missing required properties: #{missing.join(", ")}")
    return false
  end
  true
end

# -------------------------------------------------------------------
# Query Notion
# -------------------------------------------------------------------
def query_database(id)
  results, cursor = [], nil
  loop do
    body = { page_size: 100, filter: { property: "Status", select: { equals: "Published" } } }
    body[:start_cursor] = cursor if cursor
    res = notion_request("databases/#{id}/query", method: :post, body: body)
    results.concat(res["results"])
    cursor = res["next_cursor"]
    break unless res["has_more"]
  end
  puts green("📦 Retrieved #{results.size} published entries.")
  { "results" => results }
end

def fetch_page_blocks(id)
  notion_request("blocks/#{id}/children?page_size=100")["results"]
rescue => e
  puts red("⚠️ Failed to fetch page blocks: #{e.message}")
  []
end

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def clean_filename(name)
  name.to_s.downcase.gsub(/['’‘]/, "").strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

def maybe_write(path, content, desc)
  if DRY_RUN
    puts yellow("🟡 Would #{desc}: #{path}")
  else
    existed = File.exist?(path)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, content, mode: "w:UTF-8")
    puts existed ? cyan("🔄 Updated #{path}") : green("✅ Created #{path}")
    $stats[existed ? :updated : :created] += 1
  end
end

# -------------------------------------------------------------------
# Cloudinary upload
# -------------------------------------------------------------------
def upload_to_cloudinary(slug, url)
  uri = URI.parse(url)
  filename = File.basename(uri.path)
  public_id = "#{slug}-#{filename}".sub(/\.[^.]+$/, "")
  return $cache[public_id] if $cache[public_id]

  begin
    existing = Cloudinary::Api.resource(public_id)
    url = existing["secure_url"]
    $cache[public_id] = url
    puts cyan("☁️  Reusing Cloudinary asset #{public_id}")
    return url
  rescue Cloudinary::Api::NotFound
    res = Net::HTTP.get_response(uri)
    unless res.is_a?(Net::HTTPSuccess)
      puts red("⚠️ Failed to fetch #{url}")
      $stats[:failed_images] += 1
      $failed_images << { slug: slug, url: url, reason: "HTTP #{res.code}" }
      return nil
    end

    io = StringIO.new(res.body)
    upload = Cloudinary::Uploader.upload(io, public_id: public_id, resource_type: "image")
    url = upload["secure_url"]
    $cache[public_id] = url
    puts green("☁️  Uploaded #{public_id}")
    return url
  rescue => e
    puts red("⚠️ Cloudinary error for #{url}: #{e.message}")
    $stats[:failed_images] += 1
    $failed_images << { slug: slug, url: url, reason: e.message }
    return nil
  end
end

# -------------------------------------------------------------------
# Extract Notion properties
# -------------------------------------------------------------------
def extract_property_value(prop)
  return nil unless prop.is_a?(Hash) && prop["type"]

  case prop["type"]
  when "title", "rich_text"
    prop[prop["type"]].map { |t| t["plain_text"] }.join(" ")
  when "number"
    prop["number"]
  when "select"
    name = prop["select"]&.[]("name")
    name&.to_s&.sub(/^\s*[-–—•·*]+\s*/, "")&.strip
  when "multi_select"
    prop["multi_select"].map { |s| s["name"].to_s.sub(/^\s*[-–—•·*]+\s*/, "").strip }
  when "checkbox"
    prop["checkbox"]
  when "url"
    prop["url"]
  when "email"
    prop["email"]
  when "phone_number"
    prop["phone_number"]
  when "date"
    prop["date"]&.[]("start")
  when "files"
    prop["files"].map { |f| f["file"]&.[]("url") || f["external"]&.[]("url") }.compact
  end
rescue => e
  puts red("⚠️ Property parse error: #{e.message}")
  nil
end

# -------------------------------------------------------------------
# Convert blocks → markdown
# -------------------------------------------------------------------
def blocks_to_markdown(blocks, slug)
  md = +""
  blocks.each do |b|
    type, data = b["type"], b[b["type"]]

    case type
    when "paragraph"
      text = (data["rich_text"] || []).map { |t| t["plain_text"] }.join
      md << "#{text}\n\n" unless text.strip.empty?
    when "heading_1"
      md << "# #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
    when "heading_2"
      md << "## #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
    when "heading_3"
      md << "### #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
    when "bulleted_list_item"
      md << "- #{data["rich_text"].map { |t| t["plain_text"] }.join}\n"
    when "numbered_list_item"
      md << "1. #{data["rich_text"].map { |t| t["plain_text"] }.join}\n"
    when "quote"
      md << "> #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
    when "image"
      src = data["file"] ? data["file"]["url"] : data["external"]&.[]("url")
      if src && !src.empty?
        if (cloud = upload_to_cloudinary(slug, src))
          md << "![Image](#{cloud})\n\n"
        end
      end
    end
  end
  md
end

# -------------------------------------------------------------------
# Index generator
# -------------------------------------------------------------------
def update_index(path, title, type)
  title = title.is_a?(Array) ? title.first : title
  slug = clean_filename(title)
  yaml = { "layout" => "list", "title" => title.strip, "slug" => slug, "permalink" => "/#{slug}/", "generated_from_field" => type, "generated_from_value" => slug }

  content = +"---\n" + yaml.map { |k, v| "#{k}: #{v}\n" }.join + "---\n"

  maybe_write(path, content, "write index file")
end

# -------------------------------------------------------------------
# Generate markdown files
# -------------------------------------------------------------------
def generate_markdown(entries)
  valid = entries.select { |e| validate_entry(e) }

  valid.each do |item|
    title = extract_property_value(item["properties"]["Name"]) || "Untitled"
    slug = clean_filename(title)
    puts cyan("🪄 Processing #{title} (#{slug})")

    body_md = blocks_to_markdown(fetch_page_blocks(item["id"]), slug)

    # Extract Notion properties into fields
    fields = {}
    item["properties"].each do |k, v|
      val = extract_property_value(v)
      next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
      key = k.downcase.gsub(/\s*\+\s*/, "_b_").gsub(/\s+/, "_")
      fields[key] = val
    end

    fm = { "title" => title, "layout" => "place", "canonical_url" => "/places/#{slug}/", "notion_created" => Time.parse(item["created_time"]).utc.strftime("%Y-%m-%d %H:%M"), "notion_last_edited" => Time.parse(item["last_edited_time"]).utc.strftime("%Y-%m-%d %H:%M") }

    # Tags
    tags = []
    %w[category neighbourhood fb_type perfect_for].each do |k|
      val = fields[k]
      tags.concat(val.is_a?(Array) ? val : [val]) if val
    end
    fm["tags"] = tags.map { |t| clean_filename(t) }.uniq

    fields.each { |k, v| fm[k] = v unless %w[name status].include?(k) }

    grouped = { "Content" => %w[title short_description layout], "Location & Category" => %w[category neighbourhood fb_type perfect_for], "Practical Info" => %w[price address website instagram], "Media & Highlights" => %w[gallery editors_pick], "Tags" => %w[tags], "System & Metadata" => %w[canonical_url permalink generated_from_field generated_from_value notion_created notion_last_edited] }

    # Build markdown with Cloudinary fix for gallery
    md = +"---\n"
    grouped.each do |label, keys|
      md << "# ----------------------------------------\n"
      md << "# #{label}\n"
      md << "# ----------------------------------------\n"

      keys.each do |key|
        next unless fm.key?(key)
        val = fm[key]

        if val.is_a?(Array)
          md << "#{key}:\n"

          if key == "gallery"
            val.each do |url|
              next if url.nil? || url.strip.empty?
              cloud = upload_to_cloudinary(slug, url)
              md << "  - #{cloud}\n" if cloud
            end
          else
            val.each { |i| md << "  - #{i}\n" }
          end
        else
          md << "#{key}: #{val}\n"
        end
      end

      md << "\n"
    end

    # Leftover fields
    leftovers = fm.keys - grouped.values.flatten
    unless leftovers.empty?
      md << "# ----------------------------------------\n"
      md << "# Other Fields\n"
      md << "# ----------------------------------------\n"

      leftovers.each do |key|
        val = fm[key]
        if val.is_a?(Array)
          md << "#{key}:\n"
          val.each { |i| md << "  - #{i}\n" }
        else
          md << "#{key}: #{val}\n"
        end
      end
    end

    md << "---\n\n"
    md << body_md

    maybe_write("_places/#{slug}.md", md, "write place markdown")

    # Variant generation (with Cloudinary fix)
    { "category" => fields["category"], "neighbourhood" => fields["neighbourhood"], "fb_type" => fields["fb_type"], "perfect_for" => fields["perfect_for"] }.each do |type, values|
      next unless values
      Array(values).each do |v|
        folder = File.join("content", clean_filename(v))
        FileUtils.mkdir_p(folder)
        path = File.join(folder, "#{slug}.md")

        var_fm = fm.dup
        var_fm["generated_from_field"] = type
        var_fm["generated_from_value"] = clean_filename(v)
        var_fm["permalink"] = "/#{clean_filename(v)}/#{slug}/"

        variant = +"---\n"
        grouped.each do |label, keys|
          variant << "# ----------------------------------------\n"
          variant << "# #{label}\n"
          variant << "# ----------------------------------------\n"

          keys.each do |key|
            next unless var_fm.key?(key)
            val = var_fm[key]

            if val.is_a?(Array)
              variant << "#{key}:\n"

              if key == "gallery"
                val.each do |url|
                  next if url.nil? || url.strip.empty?
                  cloud = upload_to_cloudinary(slug, url)
                  variant << "  - #{cloud}\n" if cloud
                end
              else
                val.each { |i| variant << "  - #{i}\n" }
              end
            else
              variant << "#{key}: #{val}\n"
            end
          end

          variant << "\n"
        end

        leftovers = var_fm.keys - grouped.values.flatten
        unless leftovers.empty?
          variant << "# ----------------------------------------\n"
          variant << "# Other Fields\n"
          variant << "# ----------------------------------------\n"

          leftovers.each do |key|
            val = var_fm[key]
            if val.is_a?(Array)
              variant << "#{key}:\n"
              val.each { |i| variant << "  - #{i}\n" }
            else
              variant << "#{key}: #{val}\n"
            end
          end
        end

        variant << "---\n\n"
        variant << body_md

        maybe_write(path, variant, "write #{type} variant")
        update_index(File.join(folder, "index.md"), v, type)
      end
    end
  end
end

# -------------------------------------------------------------------
# Taxonomy YAML generator (writes to _data/taxonomies/*.yml)
# -------------------------------------------------------------------
def generate_taxonomy_data
  puts cyan("📚 Generating taxonomy YAML files...")

  base = "_data/taxonomies"
  FileUtils.mkdir_p(base)

  taxonomies = { "categories" => [], "neighbourhoods" => [], "fb_types" => [], "perfect_for" => [] }

  Dir
    .glob("_places/*.md")
    .each do |file|
      content = File.read(file)

      taxonomies["categories"] << Regexp.last_match(1).strip if content =~ /^category:\s*(.+)$/i

      taxonomies["neighbourhoods"] << Regexp.last_match(1).strip if content =~ /^neighbourhood:\s*(.+)$/i

      [%w[fb_type fb_types], %w[perfect_for perfect_for]].each do |search, key|
        if content =~ /^#{search}:\s*\n(.*?)(?:^[^\s-]|\Z)/m
          block = Regexp.last_match(1)
          block
            .split(/\r?\n/)
            .each do |line|
              cleaned = line.sub(/^\s*[-–—•·*]+\s*/, "").strip
              taxonomies[key] << cleaned unless cleaned.empty?
            end
        end
      end
    end

  taxonomies.each do |key, values|
    values = values.uniq.sort.map { |v| { "name" => v, "slug" => clean_filename(v) } }

    yaml = values.to_yaml
    yaml = yaml.sub(/\A---\s*\n/, "") # remove YAML document header

    File.write("#{base}/#{key}.yml", yaml)
    puts green("📄 Wrote #{base}/#{key}.yml (#{values.size} items)")
  end
end

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
start = Time.now
puts cyan("🔗 Connecting to Notion...")

entries = query_database(DATABASE_ID)["results"]

clean_folder("content")
clean_folder("_places")
clean_folder("_data/taxonomies") # leaves _data/icons.yml alone

generate_markdown(entries)
generate_taxonomy_data
save_cache($cache)

duration = Time.now - start
puts "\n📊 Summary:"
$stats.each { |k, v| puts "   #{k.to_s.ljust(15)}: #{v}" }
if $failed_images.any?
  puts "\n⚠️  Failed Images (#{$failed_images.size}):"
  $failed_images.each { |img| puts "   #{img[:slug]}: #{img[:url]} (#{img[:reason]})" }
end
puts cyan("⏱️ Completed in #{duration.round(1)} seconds.")
puts green("🎉 Done!")
