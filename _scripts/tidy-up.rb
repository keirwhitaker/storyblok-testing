#!/usr/bin/env ruby
# frozen_string_literal: true

require "fileutils"
require "dotenv"
Dotenv.load

DRY_RUN = ARGV.include?("--dry-run")

# -------------------------------------------------------------------
# Helper: Slugify
# -------------------------------------------------------------------
def clean_filename(name)
  name.to_s.downcase.strip.gsub(/[^a-z0-9]+/, "-").gsub(/^-|-$/, "")
end

# -------------------------------------------------------------------
# Load whitelist from .env (or fallback)
# -------------------------------------------------------------------
DEFAULT_SAFE_FOLDERS = %w[_data _includes _layouts _places _site img assets js css vendor node_modules .git .github]

SAFE_FOLDERS =
  if ENV["TIDY_WHITELIST"] && !ENV["TIDY_WHITELIST"].strip.empty?
    ENV["TIDY_WHITELIST"].split(",").map(&:strip)
  else
    DEFAULT_SAFE_FOLDERS
  end

puts "🧭 Whitelisted folders (never deleted):"
puts SAFE_FOLDERS.map { |f| "  - #{f}" }

# -------------------------------------------------------------------
# Collect valid folder slugs from _places
# -------------------------------------------------------------------
FIELDS = %w[neighbourhood category fb_type perfect_for]
valid_slugs = []
referenced_images = []

Dir
  .glob("_places/*.md")
  .each do |file|
    content = File.read(file)

    FIELDS.each do |field|
      case field
      when "neighbourhood", "category"
        if content =~ /^#{field}:\s*(.+)$/i
          val = Regexp.last_match(1)&.strip&.gsub(/["']/, "")
          valid_slugs << clean_filename(val) unless val.nil? || val.empty?
        end
      when "fb_type", "perfect_for"
        if content =~ /^#{field}:\s*\n(.*?)(?:^[^\s-]|\Z)/m
          raw_block = Regexp.last_match(1)
          raw_block
            .split(/\r?\n/)
            .each do |line|
              name = line.gsub(/^[\s\-–•]+/, "").strip
              next if name.empty?
              valid_slugs << clean_filename(name)
            end
        end
      end
    end

    # Collect referenced images
    content.scan(/^gallery:\s*\n(.*?)(?:^[^\s-]|\Z)/m) do |match|
      raw_block = match[0]
      raw_block
        .split(/\r?\n/)
        .each do |line|
          path = line.gsub(/^[\s\-–•]+/, "").strip
          referenced_images << path if path.start_with?("img/")
        end
    end
  end

valid_slugs.uniq!
referenced_images.uniq!

puts "\n✅ Found #{valid_slugs.size} unique folder slugs."
puts "🖼️  Found #{referenced_images.size} referenced images."

# -------------------------------------------------------------------
# Find stale folders (only top-level)
# -------------------------------------------------------------------
all_dirs = Dir.glob("*").select { |f| File.directory?(f) }
generated_dirs = all_dirs.reject { |d| SAFE_FOLDERS.include?(d) || d.start_with?("_") }

stale_dirs = generated_dirs.reject { |d| valid_slugs.include?(d) }

if stale_dirs.empty?
  puts "\n✨ No stale folders found."
else
  puts "\n🧹 The following folders no longer match Notion values:"
  stale_dirs.each { |s| puts "  - #{s}" }

  unless DRY_RUN
    stale_dirs.each do |folder|
      FileUtils.rm_rf(folder)
      puts "🗑️  Deleted folder: #{folder}"
    end
  end
end

# -------------------------------------------------------------------
# Clean up unreferenced images
# -------------------------------------------------------------------
if Dir.exist?("img")
  all_images = Dir.glob("img/*").select { |f| File.file?(f) }
  unused = all_images - referenced_images

  if unused.empty?
    puts "\n✨ No unused images found."
  else
    puts "\n🧽 Unused images (not referenced in any _places file):"
    unused.each { |img| puts "  - #{img}" }

    unless DRY_RUN
      unused.each do |img|
        FileUtils.rm_f(img)
        puts "🗑️  Deleted image: #{img}"
      end
    end
  end
else
  puts "\n⚠️  No img/ folder found — skipping image cleanup."
end

puts "\n✅ Tidy-up complete#{DRY_RUN ? " (dry run, nothing deleted)" : ""}."
