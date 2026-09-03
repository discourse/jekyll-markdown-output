# frozen_string_literal: true

module Jekyll
  module MarkdownOutput
    # Builds the Markdown bytes for a single source document.
    # Not a Jekyll::Page on purpose: we write directly to _site/
    # in a post_write hook so the converter and layout pipeline
    # cannot touch the output.
    class MarkdownPage
      DEFAULT_FRONTMATTER_KEYS = %w[title date url summary tags category author].freeze
      DEFAULT_HTML_TO_MARKDOWN_OPTIONS = {
        "unknown_tags"    => "pass_through",
        "github_flavored" => true,
        "tag_border"      => "",
      }.freeze

      attr_reader :doc, :site, :options

      def initialize(site, doc, options = {})
        @site = site
        @doc = doc
        @options = options
      end

      # Absolute path on disk where this file should be written.
      def destination
        File.join(@site.dest, relative_destination)
      end

      # Generated pages from plugins such as jekyll-redirect-from can appear
      # in site.pages without a corresponding source file on disk.
      def source_file?
        File.file?(source_path)
      end

      # Path relative to the site root, e.g. "/foo.md".
      def relative_destination
        ext = @options.fetch("extension", ".md")
        url = @doc.url
        if url.end_with?("/")
          File.join(url, "index#{ext}")
        else
          dir = File.dirname(url)
          base = File.basename(url, ".*")
          File.join(dir, "#{base}#{ext}")
        end
      end

      def to_s
        parts = []
        fm = build_frontmatter
        parts << "---\n#{fm}---" unless fm.empty?
        if @options.fetch("include_title_heading", true) && @doc.data["title"]
          parts << "# #{@doc.data["title"]}"
        end
        parts << output_body.to_s.strip
        "#{parts.join("\n\n")}\n"
      end

      private

      def build_frontmatter
        keys = @options["frontmatter_keys"] || DEFAULT_FRONTMATTER_KEYS
        url = @doc.url
        site_url = @site.config["url"]
        url = "#{site_url}#{url}" if site_url && !url.start_with?("http")

        candidates = {
          "title"    => @doc.data["title"],
          "date"     => format_date(@doc.data["date"]),
          "url"      => url,
          "summary"  => extract_summary,
          "tags"     => Array(@doc.data["tags"]).reject { |t| t.to_s.empty? },
          "category" => @doc.data["category"],
          "author"   => @doc.data["author"] || @site.config["author"],
        }

        picked = keys.each_with_object({}) do |key, h|
          v = candidates[key]
          next if v.nil?
          next if v.respond_to?(:empty?) && v.empty?
          h[key] = v
        end

        return "" if picked.empty?

        YAML.dump(picked).sub(/\A---\s*\n/, "")
      end

      def format_date(date)
        return nil if date.nil?
        date.respond_to?(:iso8601) ? date.iso8601 : date.to_s
      end

      # `summary` falls back to the document's excerpt when not set in
      # frontmatter. Excerpt may be a Jekyll::Excerpt object (whose YAML dump
      # is a huge object graph) or already a string. Coerce to plain text and
      # strip tags so it's safe to embed in YAML frontmatter.
      def extract_summary
        s = @doc.data["summary"]
        return s.strip if s.is_a?(String) && !s.strip.empty?

        excerpt = @doc.data["excerpt"]
        return nil if excerpt.nil?
        text = excerpt.respond_to?(:content) ? excerpt.content : excerpt
        text = text.to_s.gsub(/<[^>]+>/, "").strip
        text.empty? ? nil : text
      end

      # Resolve to an absolute path on disk. Document#path is already
      # absolute; Page#path is relative to the site source.
      def source_path
        File.expand_path(@doc.path.to_s, @site.source)
      end

      # Re-read the source body from disk. By the time post_write fires,
      # Jekyll has overwritten doc.content with the converted HTML.
      # Force UTF-8 because some build environments (e.g. Cloudflare Pages)
      # default to US-ASCII, which breaks regex splits on non-ASCII bytes.
      def source_body
        raw = File.read(source_path, encoding: "UTF-8")
        parts = raw.split(/^---\s*$\n/, 3)
        parts.length >= 3 ? parts[2] : raw
      end

      def rendered_source
        body = source_body
        # Skip Liquid only when the document explicitly opted out. We do not
        # rely on Document#render_with_liquid? here because Jekyll mutates
        # that flag to false after the main render pass, and our post_write
        # hook runs strictly after that.
        return body if @doc.data["render_with_liquid"] == false

        info = {
          filters:   [Jekyll::Filters],
          registers: { site: @site, page: @doc.to_liquid },
        }
        template = @site.liquid_renderer.file(source_path).parse(body)
        template.render!(@site.site_payload.merge("page" => @doc.to_liquid), info)
      rescue StandardError => e
        rel = @doc.respond_to?(:relative_path) ? @doc.relative_path : @doc.path
        Jekyll.logger.warn("MarkdownOutput:", "render failed for #{rel}: #{e.message}")
        source_body
      end

      def output_body
        body = rendered_source
        return body unless @options["html_to_markdown"] && html_source?

        body = prepare_html_for_conversion(body)

        # Preserve the source's inline spacing instead of adding a space at
        # every tag boundary (for example, before punctuation after </strong>).
        ReverseMarkdown.convert(body, html_to_markdown_options)
      end

      def prepare_html_for_conversion(body)
        fragment = Nokogiri::HTML::DocumentFragment.parse(body)

        fragment.css("template, [data-markdown-output='exclude']").remove
        expose_icon_aria_labels(fragment) if @options["include_aria_labels"]
        flatten_table_details(fragment)

        fragment.to_html
      end

      def html_source?
        %w[.html .htm].include?(File.extname(source_path).downcase)
      end

      def html_to_markdown_options
        configured = @options["html_to_markdown_options"] || {}
        DEFAULT_HTML_TO_MARKDOWN_OPTIONS.merge(configured).each_with_object({}) do |(key, value), result|
          result[key.to_sym] = value
        end
      end

      # Replace labeled SVG and <i> icons with their accessible names while
      # leaving surrounding elements (such as links and buttons) available to
      # the normal conversion pipeline.
      def expose_icon_aria_labels(fragment)
        fragment.css("svg[aria-label], i[aria-label]").each do |icon|
          label = icon["aria-label"].to_s.strip
          next if label.empty?

          icon.replace(Nokogiri::XML::Text.new(label, fragment.document))
        end
      end

      def flatten_table_details(fragment)
        fragment.css("td details, th details").each do |details|
          summary = details.at_xpath("./summary")
          next unless summary

          summary.name = "strong"
          summary.add_next_sibling(Nokogiri::XML::Text.new(" — ", fragment.document))
          details.xpath("./p").each { |paragraph| paragraph.name = "span" }
          details.name = "span"
        end
      end
    end
  end
end
