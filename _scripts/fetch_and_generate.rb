#!/usr/bin/env ruby
# frozen_string_literal: true

require "dotenv"
Dotenv.load
require "net/http"
require "json"
require "uri"
require "fileutils"
require "time"
require "base64"
require "stringio"
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
def colour(text, code)
  "\e[#{code}m#{text}\e[0m"
end
def green(text) = colour(text, 32)
def yellow(text) = colour(text, 33)
def red(text) = colour(text, 31)

$stats = { created: 0, updated: 0, deleted: 0, skipped: 0 }

# -------------------------------------------------------------------
# Cache helpers
# -------------------------------------------------------------------
def load_cache
  File.exist?(CACHE_PATH) ? JSON.parse(File.read(CACHE_PATH)) : {}
rescue JSON::ParserError
  {}
end

def save_cache(cache)
  FileUtils.mkdir_p(File.dirname(CACHE_PATH))
  File.write(CACHE_PATH, JSON.pretty_generate(cache))
  puts "💾 Updated Cloudinary cache (#{cache.size} entries)"
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
  name
    .to_s
    .downcase
    .gsub(/[’‘']/, "") # remove straight and curly apostrophes
    .strip
    .gsub(/[^a-z0-9]+/, "-") # replace remaining non-alphanumeric chars with hyphens
    .gsub(/^-|-$/, "") # trim leading/trailing hyphens
end

def maybe_write(path, content, action_desc)
  if DRY_RUN
    puts green("🟢 Would #{action_desc}: #{path}")
    $stats[:created] += 1 unless File.exist?(path)
    $stats[:updated] += 1 if File.exist?(path)
  else
    FileUtils.mkdir_p(File.dirname(path))
    existed = File.exist?(path)
    File.write(path, content)
    $stats[existed ? :updated : :created] += 1
  end
end

def update_index(path, title, type)
  title = title.is_a?(Array) ? title.first.to_s : title.to_s
  title = title.strip.sub(/^[\-\s]+/, "")
  return if title.empty?

  desc =
    case type
    when "category"
      "Places listed under the #{title.capitalize} category."
    when "neighbourhood"
      "Places located in #{title.capitalize}."
    when "fb_type"
      "Places with the F+B type #{title.capitalize}."
    when "perfect_for"
      "Places that are perfect for #{title.capitalize}."
    else
      "Places tagged as #{title.capitalize}."
    end

  data = { "layout" => "list", "title" => title.capitalize, "type" => type, "slug" => clean_filename(title), "description" => desc, "permalink" => "/#{clean_filename(title)}/" }

  File.open(path, "w") do |f|
    f.puts("---")
    data.each { |k, v| f.puts("#{k}: #{v}") }
    f.puts("---\n\n{{ description }}\n")
  end
end

def blocks_to_markdown(blocks, image_collector)
  blocks
    .map do |block|
      t = block["type"]
      d = block[t]
      case t
      when "paragraph"
        d["rich_text"].map { |x| x["plain_text"] }.join + "\n\n"
      when "heading_1"
        "# #{d["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
      when "heading_2"
        "## #{d["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
      when "heading_3"
        "### #{d["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
      when "bulleted_list_item"
        "- #{d["rich_text"].map { |x| x["plain_text"] }.join}\n"
      when "numbered_list_item"
        "1. #{d["rich_text"].map { |x| x["plain_text"] }.join}\n"
      when "quote"
        "> #{d["rich_text"].map { |x| x["plain_text"] }.join}\n\n"
      when "image"
        url = d["file"] ? d["file"]["url"] : d["external"]["url"]
        image_collector << url if url
        "![Image](#{url})\n\n"
      else
        ""
      end
    end
    .join
end

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
  warn "⚠️ Error parsing property: #{e.message}"
  nil
end

# -------------------------------------------------------------------
# Folder cleanup
# -------------------------------------------------------------------
def clean_content_folder
  base = "content"
  if Dir.exist?(base)
    FileUtils.rm_rf(base)
    puts red("🗑️  Removed existing content folder.")
  end
  FileUtils.mkdir_p(base)
end

# -------------------------------------------------------------------
# Upload image to Cloudinary (skip if cached or already exists)
# -------------------------------------------------------------------
def upload_to_cloudinary(slug, url)
  uri = URI.parse(url)
  filename = File.basename(uri.path)
  public_id = "#{slug}-#{filename}".sub(/\.[^.]+$/, "")

  # Check local cache first
  if $cache[public_id]
    puts yellow("💾 Using cached Cloudinary URL for #{public_id}")
    return $cache[public_id]
  end

  begin
    existing = Cloudinary::Api.resource(public_id)
    puts yellow("☁️  Skipping upload (already exists): #{public_id}")
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
      puts red("⚠️  Failed to fetch image: #{url}")
      return nil
    end
  end
rescue => e
  puts red("⚠️  Cloudinary error: #{e.message}")
  nil
end

# -------------------------------------------------------------------
# Main generator
# -------------------------------------------------------------------
def generate_markdown(entries)
  FileUtils.mkdir_p("_places")
  base = "content"

  entries.each do |item|
    props = item["properties"]
    title = extract_property_value(props["Name"]) || "Untitled"
    slug = clean_filename(title)
    md_path = "_places/#{slug}.md"

    body_blocks = fetch_page_blocks(item["id"])
    inline_images = []
    body_md = blocks_to_markdown(body_blocks, inline_images)

    fields = {}
    props.each do |k, v|
      next if v.nil? || !v.is_a?(Hash)
      val = extract_property_value(v)
      next if val.nil? || (val.respond_to?(:empty?) && val.empty?)
      normalised_key = k.downcase.strip.gsub(/\s*\+\s*/, "_b_").gsub(/\s+/, "_")
      fields[normalised_key] = val
    end

    ordered = %w[title neighbourhood category fb_type perfect_for editors_pick tags short_description address longitude latitude website instagram price gallery]
    fm = {}
    ordered.each { |k| fm[k] = fields[k] if fields[k] }

    now_pretty = Time.now.utc.strftime("%Y-%m-%d %H:%M")
    fm["canonical_url"] = "/places/#{slug}/"
    fm["layout"] = "place"
    fm["created_at"] = now_pretty
    fm["updated_at"] = now_pretty
    fm["last_synced"] = now_pretty

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
          v.each do |i|
            clean_item = i.to_s.strip.sub(/^[\-\s]+/, "")
            next if clean_item.empty?
            md << "  - #{clean_item}\n"
          end
        end
      else
        if v.is_a?(String)
          clean_val = v.strip.sub(/^[\-\s]+/, "")
          if k == "address" || clean_val.match?(/[,:@&]/)
            md << "#{k}: \"#{clean_val.gsub('"', '\"')}\"\n"
          else
            md << "#{k}: #{clean_val}\n"
          end
        else
          md << "#{k}: #{v}\n"
        end
      end
    end

    md << "---\n\n#{body_md.strip}\n"
    maybe_write(md_path, md, "write _places file")

    # Generate content folders
    all_values = []
    all_values << fields["category"] if fields["category"]
    all_values << fields["neighbourhood"] if fields["neighbourhood"]
    all_values << fields["fb_type"] if fields["fb_type"]
    all_values.concat(fields["perfect_for"]) if fields["perfect_for"].is_a?(Array)

    all_values.compact.each do |val|
      dir = File.join(base, clean_filename(val))
      FileUtils.mkdir_p(dir)

      # Create the place file inside this folder
      place_file_path = File.join(dir, "#{slug}.md")
      content_with_permalink = md.sub(/---\n/, "---\npermalink: /#{clean_filename(val)}/#{slug}/\n")
      maybe_write(place_file_path, content_with_permalink, "create place file in #{dir}")

      # Create or update the index (listing) page
      index_path = File.join(dir, "index.md")
      update_index(index_path, val, "collection")
    end
  end
end

# -------------------------------------------------------------------
# JSON export
# -------------------------------------------------------------------
def generate_data_files
  require "json"
  data = { categories: [], neighbourhoods: [], fb_types: [], perfect_for: [] }

  Dir
    .glob("_places/*.md")
    .each do |file|
      content = File.read(file)
      { categories: /^category:\s*(.+)$/i, neighbourhoods: /^neighbourhood:\s*(.+)$/i, fb_types: /^fb_type:\s*(.+)$/i }.each do |type, regex|
        val = content[regex, 1]&.strip&.sub(/^[\-\s]+/, "")&.gsub(/["']/, "")
        data[type] << { "name" => val, "slug" => clean_filename(val) } if val && !val.empty?
      end

      if content =~ /^perfect_for:\s*\n(.*?)(?:^[^\s-]|\Z)/m
        raw_block = Regexp.last_match(1)
        raw_block
          .split(/\r?\n/)
          .each do |line|
            name = line.gsub(/^[\s\-–•]+/, "").strip
            next if name.empty? || name.start_with?("#")
            data[:perfect_for] << { "name" => name, "slug" => clean_filename(name) }
          end
      end
    end

  FileUtils.mkdir_p("_data")
  data.each do |name, arr|
    arr = arr.uniq { |a| a["slug"] }.sort_by { |a| a["name"] }
    path = "_data/#{name}.json"
    File.write(path, JSON.pretty_generate(arr))
    puts "🗂️  Wrote #{path} (#{arr.size} items)"
  end
end

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
puts "🔗 Connecting to Notion database #{DATABASE_ID[0..7]}..."
entries = query_database(DATABASE_ID)["results"]
puts "📦 Found #{entries.size} entries."

clean_content_folder
generate_markdown(entries)
generate_data_files
save_cache($cache)

puts "\n📊 Summary:"
puts "   🟢 Created: #{$stats[:created]}"
puts "   🟢 Updated: #{$stats[:updated]}"
puts "   🔴 Deleted: #{$stats[:deleted]}"
puts "   🟡 Skipped: #{$stats[:skipped]}"
puts "🎉 Done! #{DRY_RUN ? "(Dry Run — no files modified)" : ""}"
