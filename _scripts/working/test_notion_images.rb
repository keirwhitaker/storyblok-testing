#!/usr/bin/env ruby
# frozen_string_literal: true

require "dotenv"
Dotenv.load

require "net/http"
require "json"
require "uri"
require "open-uri"
require "fileutils"

# -------------------------------------------------------------------
# Configuration
# -------------------------------------------------------------------
NOTION_TOKEN = ENV["NOTION_TOKEN"]
DATABASE_ID = ENV["NOTION_DB_ID"]

abort "❌ Missing NOTION_TOKEN or NOTION_DB_ID. Check .env" unless NOTION_TOKEN && DATABASE_ID

# -------------------------------------------------------------------
# Helpers
# -------------------------------------------------------------------
def notion_request(path, method: :get, body: nil)
  uri = URI("https://api.notion.com/v1/#{path}")
  req = Net::HTTP.const_get(method.capitalize).new(uri)
  req["Authorization"] = "Bearer #{NOTION_TOKEN}"
  req["Notion-Version"] = "2022-06-28"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body

  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) { |http| http.request(req) }
  raise "Notion API error: #{res.code} #{res.body}" unless res.code.to_i == 200
  JSON.parse(res.body)
end

def query_database(database_id)
  notion_request("databases/#{database_id}/query", method: :post, body: { page_size: 100 })
end

def fetch_page_blocks(page_id)
  notion_request("blocks/#{page_id}/children?page_size=100")["results"]
rescue StandardError
  []
end

def blocks_to_markdown(blocks, image_collector)
  blocks
    .map do |block|
      type = block["type"]
      data = block[type]
      case type
      when "paragraph"
        data["rich_text"].map { |t| t["plain_text"] }.join + "\n\n"
      when "heading_1"
        "# #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
      when "heading_2"
        "## #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
      when "heading_3"
        "### #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
      when "bulleted_list_item"
        "- #{data["rich_text"].map { |t| t["plain_text"] }.join}\n"
      when "numbered_list_item"
        "1. #{data["rich_text"].map { |t| t["plain_text"] }.join}\n"
      when "quote"
        "> #{data["rich_text"].map { |t| t["plain_text"] }.join}\n\n"
      when "image"
        image_url = data["file"] ? data["file"]["url"] : data["external"]["url"]
        image_collector << image_url if image_url
        "![Image](#{image_url})\n\n"
      else
        ""
      end
    end
    .join
end

def clean_filename(name)
  name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

def download_image(url, title, index = nil)
  return nil unless url && !url.empty?

  FileUtils.mkdir_p("assets/uploads")
  suffix = index ? "-#{index}" : ""
  filename = "#{clean_filename(title)}#{suffix}-#{File.basename(URI.parse(url).path)}"
  filepath = "assets/uploads/#{filename}"
  return filepath if File.exist?(filepath)

  uri = URI(url)
  req = Net::HTTP::Get.new(uri)
  req["Authorization"] = "Bearer #{NOTION_TOKEN}"
  req["User-Agent"] = "Ruby/#{RUBY_VERSION}"

  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true) do |http|
    res = http.request(req)
    if res.is_a?(Net::HTTPSuccess)
      File.open(filepath, "wb") { |f| f.write(res.body) }
      puts "📸  Saved image: #{filepath}"
      return filepath
    else
      warn "⚠️  Failed to fetch #{url} — #{res.code}"
      return nil
    end
  end
rescue => e
  warn "⚠️  Error saving image for #{title}: #{e.message}"
  nil
end

# Convert any Notion property to a plain Ruby value
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
    prop["files"]
      .map do |f|
        if f["file"] && f["file"]["url"]
          f["file"]["url"]
        elsif f["external"] && f["external"]["url"]
          f["external"]["url"]
        else
          nil
        end
      end
      .compact
  else
    nil
  end
rescue => e
  warn "⚠️  Error parsing property: #{e.message}"
  nil
end

# -------------------------------------------------------------------
# Generate Markdown files
# -------------------------------------------------------------------
def generate_markdown(entries)
  FileUtils.mkdir_p("_places")

  entries.each do |item|
    props = item["properties"]
    title = extract_property_value(props["Name"]) || "Untitled"
    slug = clean_filename(title)
    md_path = "_places/#{slug}.md"

    # Look for Gallery (preferred), or fall back to Image/Photos
    image_prop = props["Gallery"] || props["Image"] || props["Photos"]
    property_images = Array(extract_property_value(image_prop)).compact

    # Page body + inline images
    inline_images = []
    body_blocks = fetch_page_blocks(item["id"])
    body_markdown = blocks_to_markdown(body_blocks, inline_images)

    # Combine & download all
    all_images = (property_images + inline_images).uniq
    local_images = []
    all_images.each_with_index do |url, i|
      path = download_image(url, title, i + 1)
      local_images << path if path
    end

    # Prefer local image paths; fall back to URLs if nothing downloaded
    front_matter_gallery = local_images.any? ? local_images : all_images

    # Extract other fields
    additional_fields = {}
    skipped_fields = []

    props.each do |key, value|
      next if value.nil? || !value.is_a?(Hash)
      next if %w[Name Gallery Image Photos].include?(key) # already handled

      val = extract_property_value(value)
      if val.nil? || (val.respond_to?(:empty?) && val.empty?)
        skipped_fields << key
        next
      end

      safe_key = key.downcase.strip.gsub(/\s+/, "_")
      additional_fields[safe_key] = val
    end

    front_matter = { "layout" => "place", "title" => title, "gallery" => front_matter_gallery, "last_synced" => Time.now.utc.iso8601 }.merge(additional_fields)

    markdown = +"---\n"
    front_matter.each do |k, v|
      if v.is_a?(Array)
        markdown << "#{k}:\n"
        v.each { |item| markdown << "  - #{item}\n" }
      else
        markdown << "#{k}: #{v}\n"
      end
    end
    markdown << "---\n\n"
    markdown << body_markdown.strip
    markdown << "\n"

    File.write(md_path, markdown)
    puts "✅ Created/updated #{md_path}"
    puts "ℹ️  Skipped empty fields: #{skipped_fields.map(&:downcase).join(", ")}" unless skipped_fields.empty?
  end
end

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
puts "🔗 Connecting to Notion database #{DATABASE_ID[0..7]}..."
entries = query_database(DATABASE_ID)["results"]
puts "📦 Found #{entries.size} entries."
generate_markdown(entries)
puts "🎉 Done!"
