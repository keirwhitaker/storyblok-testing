#!/usr/bin/env ruby
# frozen_string_literal: true
# encoding: UTF-8
# Working as of Sun 30th November

require "dotenv"
Dotenv.load
require "net/http"
require "json"
require "uri"
require "fileutils"
require "time"
require "stringio"
require "base64"
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
NOTION_RATE_LIMIT_DELAY = 0.3 # seconds between requests
REQUIRED_PROPERTIES = %w[Name Status].freeze

abort "❌ Missing NOTION_TOKEN or NOTION_DB_ID. Check .env" unless NOTION_TOKEN && DATABASE_ID
abort "❌ Missing CLOUDINARY_URL. Add to .env file." unless CLOUDINARY_URL

Cloudinary.config_from_url(CLOUDINARY_URL)

# -------------------------------------------------------------------
# Colour helpers
# -------------------------------------------------------------------
def colour(text, code)
  "\e[#{code}m#{text}\e[0m"
end

def green(text) = colour(text, 32)
def yellow(text) = colour(text, 33)
def red(text) = colour(text, 31)
def cyan(text) = colour(text, 36)

$stats = { created: 0, updated: 0, deleted: 0, skipped: 0, failed_images: 0 }
$failed_images = []

# -------------------------------------------------------------------
# Cloudinary cache handling
# -------------------------------------------------------------------
def fetch_all_cloudinary_assets
  puts yellow("☁️  Rebuilding Cloudinary cache from API...")
  resources = []
  next_cursor = nil
  begin
    loop do
      res = Cloudinary::Api.resources(max_results: 500, next_cursor: next_cursor)
      resources.concat(res["resources"])
      next_cursor = res["next_cursor"]
      break unless next_cursor
    end
  rescue => e
    puts red("⚠️  Failed to fetch resources from Cloudinary: #{e.message}")
  end
  cache = {}
  resources.each { |r| cache[r["public_id"]] = r["secure_url"] }
  puts green("☁️  Retrieved #{cache.size} Cloudinary assets into cache.")
  cache
end

def load_cache
  if File.exist?(CACHE_PATH)
    begin
      content = File.read(CACHE_PATH).strip
      if content.empty?
        puts yellow("⚠️  Cache file is empty — rebuilding from Cloudinary.")
        return fetch_all_cloudinary_assets
      end
      JSON.parse(content)
    rescue JSON::ParserError => e
      puts yellow("⚠️  Cache invalid (#{e.message}) — rebuilding from Cloudinary.")
      fetch_all_cloudinary_assets
    end
  else
    puts yellow("⚠️  Cache missing — rebuilding from Cloudinary.")
    fetch_all_cloudinary_assets
  end
end

def save_cache(cache)
  FileUtils.mkdir_p(File.dirname(CACHE_PATH))
  File.write(CACHE_PATH, JSON.pretty_generate(cache))
  puts green("💾 Saved Cloudinary cache (#{cache.size} entries)")
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
  raise "Notion API error: #{res.code} - #{res.body}" unless res.code.to_i == 200
  JSON.parse(res.body)
rescue => e
  puts red("⚠️  Notion API request failed: #{e.message}")
  raise
end

# -------------------------------------------------------------------
# Validation
# -------------------------------------------------------------------
def validate_entry(entry)
  missing = REQUIRED_PROPERTIES.reject { |p| entry["properties"].key?(p) }
  if missing.any?
    puts yellow("⚠️  Entry missing required properties: #{missing.join(", ")}")
    return false
  end
  true
end

# -------------------------------------------------------------------
# Query database
# -------------------------------------------------------------------
def query_database(id)
  all_results = []
  start_cursor = nil
  loop do
    body = { page_size: 100, filter: { property: "Status", select: { equals: "Published" } } }
    body[:start_cursor] = start_cursor if start_cursor
    res = notion_request("databases/#{id}/query", method: :post, body: body)
    all_results.concat(res["results"])
    start_cursor = res["next_cursor"]
    break unless res["has_more"]
    puts yellow("↪️  Fetching next page of Notion results...")
  end
  puts green("✅ Retrieved #{all_results.size} published entries from Notion.")
  { "results" => all_results }
end

def fetch_page_blocks(id)
  notion_request("blocks/#{id}/children?page_size=100")["results"]
rescue StandardError => e
  puts red("⚠️  Failed to fetch blocks for page #{id}: #{e.message}")
  []
end

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def clean_filename(name)
  name.to_s.downcase.gsub(/['’‘]/, "").strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

def maybe_write(path, content, action_desc)
  if DRY_RUN
    puts yellow("🟡 Would #{action_desc}: #{path}")
  else
    FileUtils.mkdir_p(File.dirname(path))
    existed = File.exist?(path)
    File.write(path, content, mode: "w:UTF-8")
    puts(existed ? cyan("🔄 Updated: #{path}") : green("✅ Created: #{path}"))
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
    puts cyan("☁️  Found existing Cloudinary image: #{public_id}")
    $cache[public_id] = existing["secure_url"]
    return existing["secure_url"]
  rescue Cloudinary::Api::NotFound
    res = Net::HTTP.get_response(uri)
    if res.is_a?(Net::HTTPSuccess)
      io = StringIO.new(res.body)
      upload = Cloudinary::Uploader.upload(io, public_id: public_id, resource_type: "image")
      puts green("☁️  Uploaded #{public_id} to Cloudinary")
      $cache[public_id] = upload["secure_url"]
      return upload["secure_url"]
    else
      puts red("⚠️  Failed to fetch #{url} (HTTP #{res.code})")
      $stats[:failed_images] += 1
      $failed_images << { slug: slug, url: url, reason: "HTTP #{res.code}" }
      return nil
    end
  end
rescue => e
  puts red("⚠️  Cloudinary error for #{url}: #{e.message}")
  $stats[:failed_images] += 1
  $failed_images << { slug: slug, url: url, reason: e.message }
  nil
end

# -------------------------------------------------------------------
# Folder cleanup
# -------------------------------------------------------------------
def clean_content_folder
  base = File.expand_path("content")
  FileUtils.rm_rf(base) if Dir.exist?(base)
  FileUtils.mkdir_p(base)
  puts green("📁 Created fresh content folder.")
end

def clean_places_folder
  base = File.expand_path("_places")
  FileUtils.rm_rf(base) if Dir.exist?(base)
  FileUtils.mkdir_p(base)
  puts green("📁 Created fresh _places folder.")
end

# -------------------------------------------------------------------
# Notion property extraction
# -------------------------------------------------------------------
def extract_property_value(prop)
  return nil unless prop.is_a?(Hash) && prop["type"]
  case prop["type"]
  when "title", "rich_text"
    prop[prop["type"]].map { |t| t["plain_text"] }.join(" ")
  when "number"
    prop["number"]
  when "select"
    prop["select"]&.[]("name")
  when "multi_select"
    prop["multi_select"].map { |s| s["name"] }
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
  puts red("⚠️  Error parsing property: #{e.message}")
  nil
end

# -------------------------------------------------------------------
# Notion blocks → Markdown
# -------------------------------------------------------------------
def blocks_to_markdown(blocks, page_slug)
  counts = Hash.new(0)
  md = +""
  blocks.each do |block|
    type = block["type"]
    data = block[type]
    case type
    when "paragraph"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "#{text}\n\n" unless text.strip.empty?
    when "heading_1"
      md << "# #{data["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
    when "heading_2"
      md << "## #{data["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
    when "heading_3"
      md << "### #{data["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
    when "bulleted_list_item"
      md << "- #{data["rich_text"].map { |x| x["plain_text"] }.join}\n"
    when "numbered_list_item"
      md << "1. #{data["rich_text"].map { |x| x["plain_text"] }.join}\n"
    when "quote"
      md << "> #{data["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
    when "image"
      src = data["file"] ? data["file"]["url"] : data["external"]&.[]("url")
      next unless src && !src.strip.empty?
      cloud_url = upload_to_cloudinary(page_slug, src)
      md << "![Image](#{cloud_url})\n\n" if cloud_url
    end
  end
  [md, counts]
end

# -------------------------------------------------------------------
# Index page generator
# -------------------------------------------------------------------
def update_index(path, title, type)
  title = title.is_a?(Array) ? title.first.to_s : title.to_s
  slug = clean_filename(title)
  data = { "layout" => "list", "title" => title.strip, "slug" => slug, "permalink" => "/#{slug}/", "generated_from_field" => type, "generated_from_value" => slug }
  content = +"---\n"
  data.each { |k, v| content << "#{k}: #{v}\n" }
  content << "---\n"
  maybe_write(path, content, "update index for #{slug}")
end

# -------------------------------------------------------------------
# Markdown generator (ASCII-safe comments)
# -------------------------------------------------------------------
def generate_markdown(entries)
  FileUtils.mkdir_p("_places")
  base = "content"
  valid_entries = entries.select { |e| validate_entry(e) }
  puts yellow("⚠️  Skipping #{entries.size - valid_entries.size} invalid entries") if valid_entries.size < entries.size

  valid_entries.each do |item|
    title = extract_property_value(item["properties"]["Name"]) || "Untitled"
    slug = clean_filename(title)
    puts cyan("🪄 Processing: #{title} (#{slug})")

    blocks = fetch_page_blocks(item["id"])
    body_md, _body_counts = blocks_to_markdown(blocks, slug)

    props = item["properties"]
    fields = {}
    props.each do |k, v|
      val = extract_property_value(v)
      next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
      key = k.downcase.strip.gsub(/\s*\+\s*/, "_b_").gsub(/\s+/, "_")
      fields[key] = val
    end

    created_time = Time.parse(item["created_time"]).utc.strftime("%Y-%m-%d %H:%M")
    updated_time = Time.parse(item["last_edited_time"]).utc.strftime("%Y-%m-%d %H:%M")

    fm = { "title" => title, "layout" => "place", "canonical_url" => "/places/#{slug}/", "notion_created" => created_time, "notion_last_edited" => updated_time }

    tags = []
    %w[category neighbourhood fb_type perfect_for].each do |k|
      val = fields[k]
      tags.concat(val.is_a?(Array) ? val : [val]) if val
    end
    fm["tags"] = tags.map { |t| clean_filename(t) }.uniq.compact

    # Skip redundant Notion fields (Name, Status)
    fields.each do |k, v|
      next if %w[name status].include?(k)
      fm[k] = v unless fm.key?(k)
    end

    grouped_keys = { "Content" => %w[title short_description layout], "Location & Category" => %w[category neighbourhood fb_type perfect_for], "Practical Info" => %w[price address website instagram], "Media & Highlights" => %w[gallery editors_pick], "Tags" => %w[tags], "System & Metadata" => %w[canonical_url permalink generated_from_field generated_from_value notion_created notion_last_edited] }

    md = +"---\n"
    grouped_keys.each do |label, keys|
      md << "# ----------------------------------------\n"
      md << "# #{label}\n"
      md << "# ----------------------------------------\n"
      keys.each do |key|
        next unless fm.key?(key)
        value = fm[key]
        if value.is_a?(Array)
          md << "#{key}:\n"
          if key == "gallery"
            value.each do |url|
              next if url.nil? || url.strip.empty?
              remote_url = upload_to_cloudinary(slug, url)
              md << "  - #{remote_url}\n" if remote_url
            end
          else
            value.each { |i| md << "  - #{i}\n" }
          end
        else
          md << "#{key}: #{value}\n"
        end
      end
      md << "\n"
    end

    remaining_keys = fm.keys - grouped_keys.values.flatten
    unless remaining_keys.empty?
      md << "# ----------------------------------------\n"
      md << "# Other Fields\n"
      md << "# ----------------------------------------\n"
      remaining_keys.each do |key|
        value = fm[key]
        if value.is_a?(Array)
          md << "#{key}:\n"
          value.each { |i| md << "  - #{i}\n" }
        else
          md << "#{key}: #{value}\n"
        end
      end
    end

    md << "---\n\n"
    md << body_md unless body_md.strip.empty?

    maybe_write("_places/#{slug}.md", md, "write place file")

    # Taxonomy variants
    { "category" => fields["category"], "neighbourhood" => fields["neighbourhood"], "fb_type" => fields["fb_type"], "perfect_for" => fields["perfect_for"] }.each do |type, value|
      next unless value
      Array(value).each do |v|
        folder = File.join(base, clean_filename(v))
        FileUtils.mkdir_p(folder)
        place_file = File.join(folder, "#{slug}.md")

        variant_fm = fm.dup
        variant_fm["generated_from_field"] = type
        variant_fm["generated_from_value"] = clean_filename(v)
        variant_fm["permalink"] = "/#{clean_filename(v)}/#{slug}/"

        variant_md = +"---\n"
        grouped_keys.each do |label, keys|
          variant_md << "# ----------------------------------------\n"
          variant_md << "# #{label}\n"
          variant_md << "# ----------------------------------------\n"
          keys.each do |key|
            next unless variant_fm.key?(key)
            value2 = variant_fm[key]
            if value2.is_a?(Array)
              variant_md << "#{key}:\n"
              if key == "gallery"
                value2.each do |url|
                  next if url.nil? || url.strip.empty?
                  remote_url = upload_to_cloudinary(slug, url)
                  variant_md << "  - #{remote_url}\n" if remote_url
                end
              else
                value2.each { |i| variant_md << "  - #{i}\n" }
              end
            else
              variant_md << "#{key}: #{value2}\n"
            end
          end
          variant_md << "\n"
        end

        remaining_keys = variant_fm.keys - grouped_keys.values.flatten
        unless remaining_keys.empty?
          variant_md << "# ----------------------------------------\n"
          variant_md << "# Other Fields\n"
          variant_md << "# ----------------------------------------\n"
          remaining_keys.each do |key|
            value2 = variant_fm[key]
            if value2.is_a?(Array)
              variant_md << "#{key}:\n"
              value2.each { |i| variant_md << "  - #{i}\n" }
            else
              variant_md << "#{key}: #{value2}\n"
            end
          end
        end

        variant_md << "---\n\n"
        variant_md << body_md unless body_md.strip.empty?

        maybe_write(place_file, variant_md, "create #{type} variant")
        update_index(File.join(folder, "index.md"), v, type)
      end
    end
  end
end

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
start = Time.now
puts cyan("🔗 Connecting to Notion...")
entries = query_database(DATABASE_ID)["results"]
puts green("📦 Found #{entries.size} entries in Notion.")
clean_content_folder
clean_places_folder
generate_markdown(entries)
save_cache($cache)
duration = Time.now - start
puts "\n📊 Summary:"
$stats.each { |k, v| puts "   #{k.to_s.ljust(15)}: #{v}" }
if $failed_images.any?
  puts "\n⚠️  Failed Images (#{$failed_images.size}):"
  $failed_images.each { |img| puts "   #{img[:slug]}: #{img[:url]} (#{img[:reason]})" }
end
puts cyan("⏱️  Completed in #{duration.round(1)} seconds.")
puts green("🎉 Done! #{DRY_RUN ? "(Dry Run — no files modified)" : ""}")
