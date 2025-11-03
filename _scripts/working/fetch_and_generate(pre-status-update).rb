#!/usr/bin/env ruby
# frozen_string_literal: true

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

abort "❌ Missing NOTION_TOKEN or NOTION_DB_ID. Check .env" unless NOTION_TOKEN && DATABASE_ID
abort "❌ Missing CLOUDINARY_URL. Add to .env file." unless CLOUDINARY_URL

Cloudinary.config_from_url(CLOUDINARY_URL)

# -------------------------------------------------------------------
# Colour helpers
# -------------------------------------------------------------------
def colour(text, code) = "\e[#{code}m#{text}\e[0m"
def green(text) = colour(text, 32)
def yellow(text) = colour(text, 33)
def red(text) = colour(text, 31)
def cyan(text) = colour(text, 36)

$stats = { created: 0, updated: 0, deleted: 0, skipped: 0 }

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
    rescue JSON::ParserError
      puts yellow("⚠️  Cache invalid — rebuilding from Cloudinary.")
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
  uri = URI("https://api.notion.com/v1/#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{NOTION_TOKEN}"
  req["Notion-Version"] = "2022-06-28"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |h| h.request(req) }
  raise "Notion API error: #{res.code}" unless res.code.to_i == 200
  JSON.parse(res.body)
end

def query_database(id)
  notion_request("databases/#{id}/query", method: :post, body: { page_size: 100 })
end

def fetch_page_blocks(id)
  notion_request("blocks/#{id}/children?page_size=100")["results"]
rescue StandardError
  []
end

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def clean_filename(name)
  name.to_s.downcase.gsub(/[’‘']/, "").strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

def maybe_write(path, content, action_desc)
  if DRY_RUN
    puts yellow("🟡 Would #{action_desc}: #{path}")
  else
    FileUtils.mkdir_p(File.dirname(path))
    existed = File.exist?(path)
    File.write(path, content)
    puts(existed ? cyan("🔄 Updated: #{path}") : green("✅ Created: #{path}"))
    $stats[existed ? :updated : :created] += 1
  end
end

# -------------------------------------------------------------------
# Cloudinary uploader
# -------------------------------------------------------------------
def upload_to_cloudinary(slug, url)
  uri = URI.parse(url)
  filename = File.basename(uri.path)
  public_id = "#{slug}-#{filename}".sub(/\.[^.]+$/, "")

  if $cache[public_id]
    puts yellow("💾 Using cached Cloudinary URL for #{public_id}")
    return $cache[public_id]
  end

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
      puts red("⚠️  Failed to fetch #{url}")
      return nil
    end
  end
rescue => e
  puts red("⚠️  Cloudinary error: #{e.message}")
  nil
end

# -------------------------------------------------------------------
# Folder cleanup
# -------------------------------------------------------------------
def clean_content_folder
  base = File.expand_path("content")
  if Dir.exist?(base)
    puts yellow("🧹 Removing existing content folder (#{base})...")
    FileUtils.rm_rf(base)
    3.times do |i|
      break unless Dir.exist?(base)
      puts yellow("⚠️  Retry #{i + 1} deleting #{base}")
      sleep 0.5
      FileUtils.rm_rf(base)
    end
  end
  FileUtils.mkdir_p(base)
  puts green("📁 Created fresh content folder.")
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
# Notion blocks → Markdown (with Cloudinary for inline images)
# -------------------------------------------------------------------
def blocks_to_markdown(blocks, page_slug)
  counts = Hash.new(0)
  md = +""
  previous_list_type = nil

  blocks.each do |block|
    type = block["type"]
    data = block[type]
    case type
    when "paragraph"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      unless text.strip.empty?
        md << "#{text}\n\n"
        counts[:paragraphs] += 1
      end
    when "heading_1"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "# #{text}\n\n"
      counts[:headings] += 1
      previous_list_type = nil
    when "heading_2"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "## #{text}\n\n"
      counts[:headings] += 1
      previous_list_type = nil
    when "heading_3"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "### #{text}\n\n"
      counts[:headings] += 1
      previous_list_type = nil
    when "bulleted_list_item"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "- #{text}\n"
      counts[:bullets] += 1
      previous_list_type = :bulleted
    when "numbered_list_item"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "1. #{text}\n"
      counts[:numbers] += 1
      previous_list_type = :numbered
    when "quote"
      text = (data["rich_text"] || []).map { |x| x["plain_text"] }.join
      md << "> #{text}\n\n"
      counts[:quotes] += 1
      previous_list_type = nil
    when "image"
      src = data["file"] ? data["file"]["url"] : data["external"]&.[]("url")
      if src && !src.strip.empty?
        cloud_url = upload_to_cloudinary(page_slug, src)
        if cloud_url
          md << "![Image](#{cloud_url})\n\n"
          counts[:images] += 1
          puts cyan("📸 Inline image added for #{page_slug}")
        else
          puts yellow("⚠️  Inline image skipped (fetch/upload failed)")
        end
      end
      previous_list_type = nil
    else
      # ignore other block types for now
      previous_list_type = nil
    end

    # add a blank line after a list block if the next block isn't the same list type
    # (simple approach; keeps Markdown readable)
    # We'll peek at the next block type if present
    # Not critical—Markdown is forgiving—but keeps things tidy.
  end

  # Ensure list blocks end with a blank line
  md << "\n" if previous_list_type
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
# Markdown generator
# -------------------------------------------------------------------
def generate_markdown(entries)
  FileUtils.mkdir_p("_places")
  base = "content"

  entries.each do |item|
    title = extract_property_value(item["properties"]["Name"]) || "Untitled"
    slug = clean_filename(title)
    puts cyan("🪄 Processing: #{title} (#{slug})")

    # Notion content blocks → Markdown (with inline Cloudinary)
    blocks = fetch_page_blocks(item["id"])
    body_md, body_counts = blocks_to_markdown(blocks, slug)
    puts cyan("📝 Content extracted: #{body_counts[:paragraphs]}p, #{body_counts[:headings]}h, #{body_counts[:bullets]}•, #{body_counts[:numbers]}#, #{body_counts[:quotes]}q, #{body_counts[:images]}img")

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

    # Tags from taxonomy fields
    tags = []
    %w[category neighbourhood fb_type perfect_for].each do |k|
      val = fields[k]
      tags.concat(val.is_a?(Array) ? val : [val]) if val
    end
    fm["tags"] = tags.map { |t| clean_filename(t) }.uniq.compact

    # Merge other fields (after our core keys)
    fields.each { |k, v| fm[k] = v unless fm.key?(k) }

    # Build Markdown with front matter
    md = +"---\n"
    fm.each do |k, v|
      if v.is_a?(Array)
        md << "#{k}:\n"
        if k == "gallery"
          v.each do |url|
            next if url.nil? || url.strip.empty?
            remote_url = upload_to_cloudinary(slug, url)
            md << "  - #{remote_url}\n" if remote_url
          end
        else
          v.each { |i| md << "  - #{i}\n" }
        end
      else
        md << "#{k}: #{v}\n"
      end
    end
    md << "---\n\n"
    md << body_md unless body_md.strip.empty?

    # Save canonical _places file
    maybe_write("_places/#{slug}.md", md, "write place file")

    # Duplicate into taxonomy folders with generated_from metadata + permalink
    { "category" => fields["category"], "neighbourhood" => fields["neighbourhood"], "fb_type" => fields["fb_type"], "perfect_for" => fields["perfect_for"] }.each do |type, value|
      next unless value
      Array(value).each do |v|
        folder = File.join(base, clean_filename(v))
        FileUtils.mkdir_p(folder)
        place_file = File.join(folder, "#{slug}.md")
        content_with_meta = md.sub("---\n", "---\ngenerated_from_field: #{type}\ngenerated_from_value: #{clean_filename(v)}\npermalink: /#{clean_filename(v)}/#{slug}/\n")
        maybe_write(place_file, content_with_meta, "create #{type} variant")
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
generate_markdown(entries)
save_cache($cache)

duration = Time.now - start
puts "\n📊 Summary:"
$stats.each { |k, v| puts "   #{k.to_s.ljust(8)}: #{v}" }
puts cyan("⏱️  Completed in #{duration.round(1)} seconds.")
puts green("🎉 Done! #{DRY_RUN ? "(Dry Run — no files modified)" : ""}")
