#!/usr/bin/env bash
# Validate source references, full metadata, and list links after building the site.
set -euo pipefail
bundle exec ruby - "${1:-_site}" "${2:-}" <<'RUBY'
require 'yaml'
require 'date'
require 'bibtex'
require 'nokogiri'
require 'uri'
root, baseurl = ARGV
cv = YAML.load_file('_data/cv.yml', permitted_classes: [Date, Time])['cv']['sections']
bib = BibTeX.open('_bibliography/papers.bib')
talks = YAML.load_file('_data/talks.yml')['talks']
checks = 0
assert = lambda do |condition, message|
  abort "FAIL: #{message}" unless condition
  checks += 1
end
normalize = ->(text) { text.gsub(/\s+/, ' ').strip }
%w[en ja].each do |language|
  language_path = language == 'ja' ? '/ja' : ''
  doc = Nokogiri::HTML(File.read(File.join(root, language_path, 'cv/index.html')))
%w[Publications Talks].each do |kind|
  records = cv["Selected #{kind}"]
  section = doc.at_css("#selected-#{kind.downcase} + .card")
  assert.call(section, "Missing selected #{kind}")
  expected_heading = language == 'ja' ? (kind == 'Publications' ? '主要論文' : '主要講演') : "Selected #{kind}"
  assert.call(section.at_css('h3').text == expected_heading, 'Selected section heading is not localized')
  entries = section.css('.academic-cv-selected-info')
  references = records.reject { |entry| entry['bullet'] }
  assert.call(entries.size == references.size, "Lost or duplicated #{kind}")
  references.zip(entries).each do |reference, rendered|
    assert.call(rendered.at_css('.title'), 'Missing result title')
    assert.call(rendered.at_css('.academic-cv-selected-authors'), 'Missing authors')
    assert.call(rendered.parent.at_css('.date-column .badge'), 'Missing year badge')
    if kind == 'Publications'
      paper = bib.query("@*[key=#{reference['bibkey']}]").first
      assert.call(paper, "Unknown bibliography key: #{reference['bibkey']}")
      assert.call(normalize.call(rendered.at_css('.title').text) == normalize.call(paper[:title].to_s.delete('{}')), 'Publication title diverged from bibliography')
      assert.call(rendered.at_css('.academic-cv-selected-authors strong')&.text == 'Ryoma Ito', 'CV owner is not emphasized')
      if paper[:doi] && !paper[:doi].to_s.empty?
        href = rendered.at_css('.academic-cv-selected-links a')['href']
        assert.call(href == 'https://doi.org/' + paper[:doi].to_s.gsub('\\_', '_'), 'DOI link is missing or malformed')
      end
      %w[code website].each do |resource|
        next if paper[resource].to_s.empty?
        assert.call(rendered.css('a').any? { |link| link['href'] == paper[resource].to_s }, "Missing #{resource} link")
      end
    else
      talk = talks.find { |entry| entry['title'] == reference['talk_title'] }
      assert.call(talk, "Unknown talk: #{reference['talk_title']}")
      assert.call(rendered.at_css('.title').text == (talk["title_#{language}"] || talk['title']), 'Talk title diverged')
      assert.call(rendered.text.include?(talk["speaker_#{language}"] || talk['speaker']), 'Missing speaker') if talk['speaker']
      assert.call(rendered.text.include?(talk["description_#{language}"] || talk['description']), 'Missing talk description') if talk['description']
      %w[url slides video].each do |resource|
        next unless talk[resource]
        assert.call(rendered.css('a').any? { |link| link['href'] == talk[resource] }, "Missing talk #{resource} link")
      end
    end
  end
  assert.call(section.css('.academic-cv-selected .card').empty?, 'A result is rendered as an inner card')
  assert.call(section.css('.academic-cv-selected-links a').all? { |link| link['class'].to_s.split.include?('btn') }, 'A resource link is missing the badge class')
  footer = section.at_css('.academic-cv-selected-footer')
  assert.call(footer && section.at_css('.academic-cv-selected').element_children.last == footer, 'Full-list footer is not last')
  target = URI.join("https://example.com#{baseurl}#{language_path}/cv/", footer.at_css('a')['href']).path
  assert.call(target == "#{baseurl}#{language_path}/#{kind.downcase}/", 'Full-list link is broken')
end
end
puts "PASS: #{checks} selected CV checks"
RUBY
