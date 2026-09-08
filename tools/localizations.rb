#!/usr/bin/env ruby

require "fileutils"
require "set"

ROOT = File.expand_path("..", __dir__)
RESOURCES = File.join(ROOT, "LiquidAssPrefs", "Resources")
ENGLISH = File.join(RESOURCES, "Localizable.strings")
LOCALES = ([ENGLISH] + Dir.glob(File.join(RESOURCES, "*.lproj", "Localizable.strings"))).sort.freeze
SOURCE_GLOBS = %w[**/*.h **/*.m **/*.mm **/*.x **/*.xm].freeze
ENTRY_PATTERN = /^\s*"((?:\\.|[^"])*)"\s*=\s*"((?:\\.|[^"])*)"\s*;\s*(?:\/\/.*)?$/
REFERENCE_PATTERN = /LGLocalized\s*\(\s*@"((?:\\.|[^"])*)"\s*\)/m

Entry = Struct.new(:key, :value, :line_number)

def relative(path)
  path.delete_prefix("#{ROOT}/")
end

def parse_strings(path)
  entries = []
  broken = []

  File.readlines(path, encoding: "UTF-8").each_with_index do |line, index|
    match = ENTRY_PATTERN.match(line)
    if match
      entries << Entry.new(match[1], match[2], index + 1)
    elsif line.lstrip.start_with?('"')
      broken << index + 1
    end
  end

  [entries, broken]
end

def source_references
  references = Set.new
  SOURCE_GLOBS.each do |pattern|
    Dir.glob(File.join(ROOT, pattern)).each do |path|
      next if path.include?("/.theos/")

      File.read(path, encoding: "UTF-8").scan(REFERENCE_PATTERN) do |match|
        references << match.first
      end
    end
  end
  references
end

def duplicate_keys(entries)
  entries.group_by(&:key).select { |_key, occurrences| occurrences.length > 1 }
end

def validate(verbose: true)
  references = source_references
  english_entries, english_broken = parse_strings(ENGLISH)
  english_keys = english_entries.map(&:key).to_set
  missing_english = references - english_keys
  dead_english = english_keys - references
  failed = false

  puts "English: #{english_keys.length} keys, source: #{references.length} keys" if verbose

  unless english_broken.empty?
    failed = true
    warn "ERROR #{relative(ENGLISH)}: broken entries on lines #{english_broken.join(', ')}"
  end

  english_duplicates = duplicate_keys(english_entries)
  english_duplicates.each do |key, entries|
    failed = true
    warn "ERROR #{relative(ENGLISH)}: duplicate #{key.inspect} on lines #{entries.map(&:line_number).join(', ')}"
  end

  unless missing_english.empty?
    failed = true
    missing_english.sort.each { |key| warn "ERROR missimg english key: #{key}" }
  end

  unless dead_english.empty?
    failed = true
    dead_english.sort.each { |key| warn "ERROR dead english key: #{key}" }
  end

  LOCALES.drop(1).each do |path|
    entries, broken = parse_strings(path)
    keys = entries.map(&:key).to_set
    unknown = keys - english_keys
    missing = english_keys - keys

    unless broken.empty?
      failed = true
      warn "ERROR #{relative(path)}: broken entries on lines #{broken.join(', ')}"
    end

    duplicate_keys(entries).each do |key, occurrences|
      failed = true
      warn "ERROR #{relative(path)}: duplicate #{key.inspect} on lines #{occurrences.map(&:line_number).join(', ')}"
    end

    unless unknown.empty?
      failed = true
      unknown.sort.each { |key| warn "ERROR #{relative(path)}: unknown key #{key}" }
    end

    puts format("%-62s %3d translated, %3d missing", relative(path), keys.length, missing.length) if verbose
  end

  puts(failed ? "localization validation failed" : "localization validation passed") if verbose
  !failed
end

def clean_file(path, allowed_keys)
  removed = []
  output = File.readlines(path, encoding: "UTF-8").reject do |line|
    match = ENTRY_PATTERN.match(line)
    should_remove = match && !allowed_keys.include?(match[1])
    removed << match[1] if should_remove
    should_remove
  end

  contents = output.join.gsub(/\n{3,}/, "\n\n")
  contents << "\n" unless contents.end_with?("\n")
  temporary = "#{path}.tmp.#{$$}"
  File.write(temporary, contents, mode: "w", encoding: "UTF-8")
  File.rename(temporary, path)
  removed
ensure
  FileUtils.rm_f(temporary) if defined?(temporary)
end

def clean
  references = source_references
  removed_total = 0
  removed = clean_file(ENGLISH, references)
  removed_total += removed.length
  puts "#{relative(ENGLISH)}: removed #{removed.length} dead keys"

  english_entries, = parse_strings(ENGLISH)
  english_keys = english_entries.map(&:key).to_set
  LOCALES.drop(1).each do |path|
    removed = clean_file(path, english_keys)
    removed_total += removed.length
    puts "#{relative(path)}: removed #{removed.length} obsolete keys"
  end

  puts "Removed #{removed_total} localization entries."
  exit 1 unless validate
end

def sync
  exit 1 unless validate

  english_entries, = parse_strings(ENGLISH)
  added_total = 0

  LOCALES.drop(1).each do |path|
    temporary = nil
    locale_entries, = parse_strings(path)
    locale_keys = locale_entries.map(&:key).to_set
    missing = english_entries.reject { |entry| locale_keys.include?(entry.key) }

    if missing.empty?
      puts "#{relative(path)}: already complete"
      next
    end

    contents = File.read(path, encoding: "UTF-8").rstrip
    additions = missing.map { |entry| %Q{"#{entry.key}" = "#{entry.value}";} }.join("\n")
    contents = "#{contents}\n\n#{additions}\n" # TODO: Translate synced English fallback strings
    temporary = "#{path}.tmp.#{$$}"
    File.write(temporary, contents, mode: "w", encoding: "UTF-8")
    File.rename(temporary, path)
    added_total += missing.length
    puts "#{relative(path)}: added #{missing.length} English fallback strings"
  ensure
    FileUtils.rm_f(temporary) if temporary
  end

  puts "Added #{added_total} entries across #{LOCALES.length - 1} locales."
  exit 1 unless validate
end

def export_template(destination)
  exit 1 unless validate

  contents = File.read(ENGLISH, encoding: "UTF-8")
  if destination
    path = File.expand_path(destination, Dir.pwd)
    FileUtils.mkdir_p(File.dirname(path))
    File.write(path, contents, mode: "w", encoding: "UTF-8")
    puts "Exported #{File.size(path)} bytes to #{path}"
  else
    print contents
  end
end

def usage
  <<~TEXT
    Usage: tools/localizations.rb COMMAND [PATH]

      validate                 see if stuff are correct
      clean                    remove unused english keys and translated keys
      sync                     add missing locale keys using english values
      export-template [PATH]   export active english strings to PATH, or stdout
  TEXT
end

case ARGV.shift
when "validate"
  exit(validate ? 0 : 1)
when "clean"
  clean
when "sync"
  sync
when "export-template"
  export_template(ARGV.shift)
when "-h", "--help", nil
  puts usage
else
  warn usage
  exit 64
end
