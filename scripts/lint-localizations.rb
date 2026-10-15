#!/usr/bin/env ruby

require "json"
require "pathname"
require "yaml"

ROOT = Pathname.new(__dir__).parent.expand_path
REQUIRED_LANGUAGES = ["pt-BR", "it"].freeze

CATALOGS = [
  { path: "OpenCodeIOSClient/Localizable.xcstrings", target: "OpenCodeIOSClient", table: "Localizable" },
  { path: "OpenCodeIOSClient/AppShortcuts.xcstrings", target: "OpenCodeIOSClient", table: "AppShortcuts" },
  { path: "OpenCodeIOSClient/InfoPlist.xcstrings", info_target: "OpenCodeIOSClient" },
  { path: "DSHClient/InfoPlist.xcstrings", info_target: "DSHClient" },
  { path: "OpenCodeIOSClient/Localizable.xcstrings", target: "DSHClient", table: "Localizable" },
  { path: "OpenCodeIOSClient/AppShortcuts.xcstrings", target: "DSHClient", table: "AppShortcuts" },
  { path: "OpenCodeChatActivityExtension/Localizable.xcstrings", target: "OpenCodeChatActivityExtension", table: "Localizable" },
  { path: "OpenCodeChatActivityExtension/InfoPlist.xcstrings", info_target: "OpenCodeChatActivityExtension" },
  { path: "OpenCodeShareExtension/Localizable.xcstrings", target: "OpenCodeShareExtension", table: "Localizable" },
  { path: "OpenCodeShareExtension/InfoPlist.xcstrings", info_target: "OpenCodeShareExtension" },
].freeze

SOURCE_GLOBS = [
  "OpenCodeIOSClient/**/*.swift",
  "OpenCodeChatActivityExtension/**/*.swift",
  "OpenCodeShareExtension/**/*.swift",
  "OpenCodeShared/**/*.swift",
].freeze

UI_LITERAL_PATTERN = /(?:\.(?:text|title|prompt|accessibilityLabel|accessibilityHint|accessibilityValue)\s*=\s*|setTitle\(\s*)"((?:\\.|[^"\\])*)"/
PLACEHOLDER_PATTERN = /%(?:(\d+)\$)?(#@[A-Za-z0-9_]+@|lld|ld|lf|d|f|@|%)|\$\{applicationName\}/

def fail_lint(errors)
  return if errors.empty?

  warn "Localization lint failed:"
  errors.each { |error| warn "  - #{error}" }
  exit 1
end

def load_catalog(relative_path, errors)
  path = ROOT.join(relative_path)
  JSON.parse(path.read)
rescue Errno::ENOENT
  errors << "Missing catalog: #{relative_path}"
  nil
rescue JSON::ParserError => error
  errors << "Invalid JSON in #{relative_path}: #{error.message}"
  nil
end

def states_in(value)
  case value
  when Hash
    value.flat_map do |key, child|
      key == "state" ? [child] : states_in(child)
    end
  when Array
    value.flat_map { |child| states_in(child) }
  else
    []
  end
end

def localized_values(value)
  case value
  when Hash
    value.flat_map do |key, child|
      if key == "value" && child.is_a?(String)
        [child]
      elsif key == "values" && child.is_a?(Array)
        child.select { |item| item.is_a?(String) }
      else
        localized_values(child)
      end
    end
  when Array
    value.flat_map { |child| localized_values(child) }
  else
    []
  end
end

def placeholders(value)
  implicit_index = 0
  value.to_enum(:scan, PLACEHOLDER_PATTERN).map do
    match = Regexp.last_match
    token = match[0]
    next "applicationName" if token == "${applicationName}"

    type = match[2]
    next "literal:%" if type == "%"
    next "plural:#{type}" if type.start_with?("#@") && match[1].nil?

    index = match[1]&.to_i
    unless index
      implicit_index += 1
      index = implicit_index
    end
    "#{index}:#{type}"
  end.sort
end

def validate_placeholders(path, key, source_values, translated_values, language, errors)
  if source_values.length > 1 && source_values.length != translated_values.length
    errors << "#{path}: #{key.inspect} has #{source_values.length} source values but #{translated_values.length} #{language} values"
    return
  end

  translated_values.each_with_index do |translation, index|
    source = source_values.length == 1 ? source_values.first : source_values[index]
    next if placeholders(source) == placeholders(translation)

    errors << "#{path}: placeholders differ for #{key.inspect} in #{language}"
  end
end

def validate_catalog(spec, catalog, errors)
  path = spec.fetch(:path)
  unless catalog["sourceLanguage"] == "en"
    errors << "#{path}: sourceLanguage must be en"
  end

  strings = catalog["strings"]
  unless strings.is_a?(Hash) && !strings.empty?
    errors << "#{path}: strings must be a non-empty object"
    return
  end

  strings.each do |key, entry|
    unless entry.is_a?(Hash)
      errors << "#{path}: invalid entry for #{key.inspect}"
      next
    end

    if entry["extractionState"] == "stale"
      errors << "#{path}: stale entry #{key.inspect}"
    end

    localizations = entry["localizations"]
    source_values = if localizations.is_a?(Hash) && localizations["en"]
      localized_values(localizations["en"])
    else
      [key]
    end
    source_values = [key] if source_values.empty?

    REQUIRED_LANGUAGES.each do |language|
      localization = localizations.is_a?(Hash) ? localizations[language] : nil
      unless localization.is_a?(Hash)
        errors << "#{path}: missing #{language} translation for #{key.inspect}"
        next
      end

      states = states_in(localization)
      if states.empty? || states.any? { |state| state != "translated" }
        errors << "#{path}: incomplete #{language} translation for #{key.inspect}"
      end

      translated_values = localized_values(localization)
      if translated_values.empty?
        errors << "#{path}: empty #{language} translation for #{key.inspect}"
        next
      end
      if !key.empty? && translated_values.any? { |value| value.strip.empty? }
        errors << "#{path}: blank #{language} translation for #{key.inspect}"
      end

      validate_placeholders(path, key, source_values, translated_values, language, errors)
    end
  end
end

def ignored_ui_literal?(value, line)
  value.empty? || value.match?(/\A[0-9.]+\z/) || value.match?(/\A\\\(.+\)\z/) || line.include?("surface=")
end

def validate_source_literals(errors)
  SOURCE_GLOBS.flat_map { |pattern| Dir.glob(ROOT.join(pattern)) }.uniq.sort.each do |path|
    next if path.include?("Tests/")
    next if File.basename(path).match?(/Preview|Screenshot/)

    File.foreach(path, encoding: "UTF-8").with_index(1) do |line, line_number|
      line.scan(UI_LITERAL_PATTERN).each do |match|
        value = match.first
        next if ignored_ui_literal?(value, line)

        relative_path = Pathname.new(path).relative_path_from(ROOT)
        errors << "#{relative_path}:#{line_number}: direct UI string literal #{value.inspect}; use LocalizedStringResource or String(localized:)"
      end
    end
  end
end

def emitted_entries(stringsdata_root, target, table, errors)
  pattern = File.join(stringsdata_root, "#{target}.build", "Objects-normal", "**", "*.stringsdata")
  paths = Dir.glob(pattern)
  if paths.empty?
    return {} if ENV["EFFECTIVE_PLATFORM_NAME"] == "-maccatalyst" && target != "OpenCodeIOSClient"

    errors << "No .stringsdata found for #{target} under #{stringsdata_root}"
    return {}
  end

  entries = {}
  paths.each do |path|
    data = JSON.parse(File.read(path))
    Array(data.dig("tables", table)).each do |entry|
      key = entry["key"]
      next unless key

      values = entry["values"]&.select { |value| value.is_a?(String) }
      entries[key] = values if values && !values.empty?
      entries[key] ||= nil
    end
  rescue JSON::ParserError => error
    errors << "Invalid stringsdata #{path}: #{error.message}"
  end
  entries
end

def validate_extraction(stringsdata_root, loaded_catalogs, errors)
  CATALOGS.each do |spec|
    next unless spec[:target] && spec[:table]
    # The standalone DSH scheme does not build the OpenClient app/extensions.
    # The existing shipping-app lane continues to require their extraction.
    if ENV["TARGET_NAME"] == "DSHClient"
      next unless spec[:target] == "DSHClient"
    else
      next if spec[:target] == "DSHClient"
    end

    emitted = emitted_entries(stringsdata_root, spec[:target], spec[:table], errors)
    catalog = loaded_catalogs[spec[:path]]
    next unless catalog

    tracked_entries = catalog.fetch("strings", {})
    missing = emitted.keys - tracked_entries.keys
    missing.each do |key|
      errors << "#{spec[:path]}: compiler-emitted key is not cataloged: #{key.inspect}"
    end

    emitted.each do |key, values|
      next unless values
      next unless tracked_entries[key]

      localizations = tracked_entries[key]["localizations"]
      tracked_values = localizations.is_a?(Hash) ? localized_values(localizations["en"]) : []
      unless tracked_values == values
        errors << "#{spec[:path]}: compiler-emitted values changed for #{key.inspect}; synchronize the catalog"
      end
    end
  end
end

def validate_info_plist_sources(loaded_catalogs, errors)
  project = YAML.safe_load(ROOT.join("project.yml").read, aliases: true)
  targets = project.fetch("targets", {})

  CATALOGS.each do |spec|
    next unless spec[:info_target]

    target = targets.fetch(spec[:info_target], {})
    properties = target.dig("info", "properties") || {}
    localizable_properties = properties.select do |key, value|
      value.is_a?(String) && (key == "CFBundleDisplayName" || key.end_with?("UsageDescription"))
    end
    catalog = loaded_catalogs[spec[:path]]
    next unless catalog

    entries = catalog.fetch("strings", {})
    localizable_properties.each do |key, source_value|
      entry = entries[key]
      unless entry
        errors << "#{spec[:path]}: missing Info.plist key #{key.inspect} from #{spec[:info_target]}"
        next
      end

      english = entry.dig("localizations", "en")
      values = localized_values(english)
      unless values == [source_value]
        errors << "#{spec[:path]}: English value for #{key.inspect} does not match project.yml"
      end
    end
  end
rescue Psych::SyntaxError => error
  errors << "Invalid project.yml: #{error.message}"
end

stringsdata_root = nil
if ARGV.any?
  unless ARGV.length == 2 && ARGV.first == "--stringsdata-root"
    warn "Usage: ruby scripts/lint-localizations.rb [--stringsdata-root PATH]"
    exit 2
  end
  stringsdata_root = File.expand_path(ARGV.last)
end

errors = []
loaded_catalogs = {}
CATALOGS.each do |spec|
  catalog = load_catalog(spec[:path], errors)
  next unless catalog

  loaded_catalogs[spec[:path]] = catalog
  validate_catalog(spec, catalog, errors)
end

validate_source_literals(errors)
validate_info_plist_sources(loaded_catalogs, errors)
validate_extraction(stringsdata_root, loaded_catalogs, errors) if stringsdata_root
fail_lint(errors)

entry_count = loaded_catalogs.values.sum { |catalog| catalog.fetch("strings", {}).length }
mode = stringsdata_root ? "catalogs, source literals, and compiler extraction" : "catalogs and source literals"
puts "Localization lint passed: #{entry_count} entries across #{loaded_catalogs.length} catalogs; checked #{mode}."
