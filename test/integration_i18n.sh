#!/usr/bin/env bash
# Validate the generated site. Build first; optional arguments: destination, baseurl.
set -euo pipefail
bundle exec ruby - "${1:-_site}" "${2:-}" <<'RUBY'
require 'nokogiri'
require 'yaml'
require 'date'
require 'uri'
require 'bibtex'
root, baseurl = ARGV
config = YAML.load_file('_config.yml', permitted_classes: [Date, Time])
checks = 0
bibliography_entries = BibTeX.open('_bibliography/papers.bib').entries.values
expected_domestic_count = bibliography_entries.count { |entry| entry[:pubtype].to_s == 'domestic' }
expected_other_count = bibliography_entries.count { |entry| entry[:pubtype].to_s == 'other' }
assert = lambda do |condition, message|
  abort "FAIL: #{message}" unless condition
  checks += 1
end
load_page = lambda do |url|
  path = File.join(root, url, 'index.html')
  assert.call(File.file?(path), "Missing page: #{url}")
  Nokogiri::HTML(File.read(path))
end
pairs = ['', 'cv/', 'publications/', 'talks/', 'news/']
docs = {}
pairs.each do |suffix|
  %w[en ja].each do |lang|
    prefix = lang == 'ja' ? '/ja/' : '/'
    other_prefix = lang == 'ja' ? '/' : '/ja/'
    doc = load_page.call(prefix + suffix)
    docs[[lang, suffix]] = doc
    assert.call(doc.css('.post-header .post-description').all? { |node| node.text.strip.empty? }, "Japanese page description remains: #{prefix}#{suffix}") if lang == 'ja'
    assert.call(doc.at_css('html')['lang'] == lang, "Wrong html language: #{prefix}#{suffix}")
    switch = doc.at_css('#navbar nav[aria-label]')
    assert.call(switch && switch.at_css('a')['href'] == baseurl + other_prefix + suffix, "Language switch loses page or baseurl: #{prefix}#{suffix}")
    assert.call(switch.at_css('[aria-current]')['lang'] == lang, "Current language is unmarked: #{prefix}#{suffix}")
    nav_paths = doc.css('#navbarNav > ul > li > a.nav-link').map { |a| a['href'] }
    expected = ['', 'cv/', 'publications/', 'talks/'].map { |s| baseurl + prefix + s }
    assert.call(nav_paths == expected, "Wrong language or duplicate navigation: #{prefix}#{suffix}")
    %w[en ja x-default].each do |locale|
      alternate = doc.at_css("head link[hreflang='#{locale}']")
      target = locale == 'ja' ? '/ja/' + suffix : '/' + suffix
      assert.call(alternate && alternate['href'] == config['url'] + baseurl + target, "Wrong hreflang #{locale}: #{prefix}#{suffix}")
    end
    canonical = doc.at_css('head link[rel=canonical]')
    assert.call(canonical['href'] == config['url'] + baseurl + prefix + suffix, "Wrong canonical: #{prefix}#{suffix}")
    styles = doc.css('head link[rel=stylesheet]').map { |l| l['href'] }
    assert.call(styles.any? { |href| href.start_with?(baseurl + '/assets/css/tailwind.css') }, "Shared styles or baseurl missing: #{prefix}#{suffix}")
    doc.css('a[href]').each do |link|
      href = link['href']
      next unless href.start_with?('/') && !href.start_with?('//')
      next unless href.end_with?('/')
      assert.call(href.start_with?(baseurl + '/'), "Unprefixed internal link #{href}: #{prefix}#{suffix}")
      assert.call(File.file?(File.join(root, href.delete_prefix(baseurl), 'index.html')), "Broken internal link #{href}: #{prefix}#{suffix}")
    end
  end
end
ja_home = docs[['ja', '']]
assert.call(ja_home.at_css('#home-bio').text == '自己紹介', 'Japanese home biography heading is missing')
assert.call(ja_home.css('.academic-prose p').size >= 3, 'Biography Markdown did not render into paragraphs')
news_records = Dir.glob('_news/**/*.md').map do |path|
  YAML.safe_load(File.read(path).split(/^---\s*$/)[1], permitted_classes: [Date, Time])
end
%w[en ja].each do |lang|
  expected_news = news_records.count { |record| !record['lang'] || record['lang'] == lang }
  ['', 'news/'].each do |page_path|
    assert.call(docs[[lang, page_path]].css('.academic-news-entry').size == expected_news, "News entries were duplicated, lost, or shown in the wrong language: #{lang}/#{page_path}")
  end
end
expected_ja_news = news_records.count { |record| !record['lang'] || record['lang'] == 'ja' }
assert.call(!!ja_home.at_css('details.academic-news-more') == (expected_ja_news > 5), 'Older-news disclosure does not match the Japanese news count')
assert.call(ja_home.css('.academic-news-entry-body').any? { |body| body.text.include?('採択されました') }, 'Japanese news translation is missing')
assert.call(ja_home.at_css('.academic-news-badge[data-news-type=journal]'), 'Translated category broke shared CSS selectors')
%w[en ja].each do |lang|
  cv = docs[[lang, 'cv/']]
  expected = lang == 'ja' ? '担当講義' : 'Lectures'
  assert.call(cv.css('h3').any? { |h| h.text == expected }, "CV teaching heading missing: #{lang}")
  assert.call(cv.at_css('.academic-teaching-education'), "CV teaching rows missing: #{lang}")
  service_groups = cv.css('.academic-service-group')
  expected_headings = lang == 'ja' ? ['国際論文誌・国際会議', '国内論文誌・国内会議'] : ['Editorial Board', 'Program Committee', 'Conference Organization']
  assert.call(service_groups.css('h4').map { |heading| heading.text.strip } == expected_headings, "CV service groups incorrect: #{lang}")
  if lang == 'ja'
    assert.call(service_groups[0].css('li.list-group-item').size == 12, 'International service entries lost')
    assert.call(service_groups[1].css('li.list-group-item').size == 11, 'Domestic service entries missing')
    assert.call(service_groups[0].text.include?('FSE 2026') && !service_groups[0].text.include?('SCIS 2026'), 'Domestic service leaked into international group')
    assert.call(service_groups[1].text.include?('SCIS 2026') && !service_groups[1].text.include?('FSE 2026'), 'International service leaked into domestic group')
  end
end
assert.call(docs[['ja', 'cv/']].at_css('.cv').text.include?('博士（工学）'), 'Japanese CV data was not selected')
assert.call(docs[['ja', 'cv/']].css('h3').any? { |h| h.text == '職歴' }, 'Japanese CV headings are missing')
%w[journal-papers conference-papers preprint-papers].each do |section|
  selector = "[aria-labelledby='#{section}'] .bibliography > li"
  assert.call(docs[['en', 'publications/']].css(selector).size == docs[['ja', 'publications/']].css(selector).size, "Shared bibliography diverged: #{section}")
end
assert.call(docs[['ja', 'publications/']].css('.bibliography > li').size > 0, 'Bibliography did not render')
%w[en ja].each do |lang|
  cv = docs[[lang, 'cv/']]
  if lang == 'ja'
    assert.call(cv.at_css('#research-funding + .card a[href*="24H00696"]'), 'Japanese funding entry missing')
    assert.call(cv.css('#media-coverage + .card h6.title a').size == 4, 'Japanese media entries missing')
    keys = cv.css('.cv > a.anchor').map { |anchor| anchor['id'] }
    assert.call(keys.index('media-coverage') == keys.index('research-funding') + 1, 'Funding is not immediately before media')
  else
    assert.call(cv.css('#research-funding, #media-coverage').empty?, 'Japanese-only sections leaked into English CV')
  end
  headings = cv.css('.cv h3')
  ids = headings.map { |heading| heading['id'] }
  assert.call(ids.all? { |id| id && !id.empty? } && ids.uniq.size == ids.size, "CV heading targets missing or duplicated: #{lang}")
  pdf = cv.at_css('.post-title a[href$=".pdf"]')
  expected_pdf = lang == 'ja' ? '/assets/pdf/CV_Ja.pdf' : '/assets/pdf/CV_En.pdf'
  assert.call(pdf && pdf['href'] == baseurl + expected_pdf, "Wrong CV PDF link: #{lang}")
  assert.call(File.file?(File.join(root, expected_pdf)), "CV PDF is not published: #{lang}")
  publications = docs[[lang, 'publications/']]
  if lang == 'ja'
    assert.call(publications.at_css('#other-papers')&.text == 'その他', 'Japanese other heading missing')
    assert.call(publications.css('.academic-section').last['aria-labelledby'] == 'other-papers', 'Other papers are not the last section')
    assert.call(publications.at_css('[aria-labelledby="other-papers"] .academic-count').text.strip.split.first.to_i == expected_other_count, 'Other paper count is wrong')
    assert.call(publications.at_css('#domestic-papers'), 'Japanese domestic paper section missing')
    assert.call(publications.at_css('[aria-labelledby="domestic-papers"] .academic-count').text.strip.split.first.to_i == expected_domestic_count, 'Domestic paper count is wrong')
  else
    assert.call(publications.css('[aria-labelledby="other-papers"]').empty?, 'Other papers leaked into English page')
    assert.call(publications.css('[aria-labelledby="domestic-papers"]').empty?, 'Domestic papers leaked into English page')
  end
end
assert.call(docs[['ja', 'publications/']].at_css('#domestic-papers').text == '国内会議論文（査読無）', 'Domestic heading is untranslated')
assert.call(docs[['ja', 'cv/']].css('h3').any? { |h| h.text == '競争的研究資金' }, 'Funding heading is untranslated')
assert.call(docs[['ja', 'cv/']].css('h3').any? { |h| h.text == 'メディア報道' }, 'Media heading is untranslated')
ja_talks = docs[['ja', 'talks/']]
assert.call(ja_talks.css('[aria-labelledby="talks"] .academic-talk-card').size == docs[['en', 'talks/']].css('[aria-labelledby="talks"] .academic-talk-card').size, 'Shared talk records diverged')
invited_records = YAML.load_file('_data/talks.yml')['invited_talks'] || []
assert.call(ja_talks.css('[aria-labelledby="invited-talks"] .academic-talk-card').size == invited_records.size, 'Japanese invited talks were lost')
english_invited = invited_records.count { |record| record['language'] == 'en' }
english_talks = docs[['en', 'talks/']]
assert.call(english_talks.css('[aria-labelledby="invited-talks"] .academic-talk-card').size == english_invited, 'English invited-talk language filter is wrong')
assert.call(english_talks.css('[aria-labelledby="invited-talks"]').empty?, 'Empty invited section remains on English page') if english_invited == 0
assert.call(ja_talks.text.include?('採択率：8.2%'), 'Japanese talk field override is missing')
assert.call(ja_talks.at_css('.academic-talk-card .title').text.include?('Payload Compromised'), 'Untranslated talk title did not fall back to English')
# An untranslated legacy page offers a valid Japanese home fallback.
legacy_path = File.join(root, 'research/index.html')
if File.file?(legacy_path)
  legacy = Nokogiri::HTML(File.read(legacy_path))
  assert.call(legacy.at_css('#navbar a[hreflang=ja]')['href'] == baseurl + '/ja/', 'Legacy page language fallback is broken')
end
puts "PASS: #{checks} bilingual site checks (baseurl=#{baseurl.inspect})"
RUBY
