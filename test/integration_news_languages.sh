#!/usr/bin/env bash
# Build isolated fixtures without adding sample announcements to the real site.
set -euo pipefail
bundle exec ruby <<'RUBY'
require 'jekyll'
require 'nokogiri'
require 'tmpdir'
require 'fileutils'

Dir.mktmpdir('news-languages-') do |source|
  %w[_includes _data/content _news/ja _news/en].each { |path| FileUtils.mkdir_p(File.join(source, path)) }
  %w[academic_news.liquid i18n.liquid].each do |name|
    FileUtils.cp(File.join('_includes', name), File.join(source, '_includes', name))
  end
  %w[en ja].each do |lang|
    FileUtils.cp_r(File.join('_data/content', lang), File.join(source, '_data/content', lang))
    { 'home' => 5, 'news' => 1000 }.each do |name, limit|
      File.write(File.join(source, "#{lang}-#{name}.html"), "---\nlang: #{lang}\n---\n{% include academic_news.liquid limit=#{limit} %}")
    end
  end
  write_news = lambda do |path, metadata, body|
    File.write(File.join(source, '_news', "#{path}.md"), "---\ndate: 2026-10-10\ninline: true\n#{metadata}---\n\n#{body}\n")
  end
  write_news.call('shared', "content_ja: SHARED_JA\n", 'SHARED_EN')
  write_news.call('fallback', '', 'SHARED_FALLBACK')
  6.times { |index| write_news.call("ja/only-#{index}", "lang: ja\n", "JA_ONLY_#{index}") }
  write_news.call('en/only', "lang: en\n", 'EN_ONLY')

  destination = File.join(source, '_site')
  site = Jekyll::Site.new(Jekyll.configuration({
    'source' => source, 'destination' => destination, 'config' => [],
    'plugins' => [], 'theme' => nil, 'collections' => { 'news' => { 'output' => false } },
    'quiet' => true
  }))
  site.process
  %w[en ja].each do |lang|
    %w[home news].each do |page|
      html = Nokogiri::HTML(File.read(File.join(destination, "#{lang}-#{page}.html")))
      bodies = html.css('.academic-news-entry-body').map { |body| body.text.strip }
      expected = lang == 'ja' ? ['SHARED_JA', 'SHARED_FALLBACK', *6.times.map { |i| "JA_ONLY_#{i}" }] : ['SHARED_EN', 'SHARED_FALLBACK', 'EN_ONLY']
      abort "FAIL: wrong content for #{lang}/#{page}: #{bodies.inspect}" unless bodies.sort == expected.sort
      abort "FAIL: empty row in #{lang}/#{page}" if bodies.any?(&:empty?)
      disclosure = html.at_css('details.academic-news-more')
      if lang == 'ja' && page == 'home'
        abort 'FAIL: Japanese visible count' unless html.at_css('.academic-news-list').css('.academic-news-entry').size == 5
        abort 'FAIL: Japanese older count' unless disclosure && disclosure.css('.academic-news-entry').size == 3
        abort 'FAIL: Japanese summary count' unless disclosure.at_css('summary').text.include?('(3')
      else
        abort "FAIL: unexpected disclosure in #{lang}/#{page}" if disclosure
      end
    end
  end
end
puts 'PASS: shared, Japanese-only, English-only news, translation fallback, and per-language pagination'
RUBY
