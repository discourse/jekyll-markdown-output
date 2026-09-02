# frozen_string_literal: true

# These specs exercise MarkdownPage in isolation. They write real source files
# into a tmp dir (because source_body reads from disk) and set
# `render_with_liquid: false` in the doc data so the Liquid render path is
# skipped — Liquid is covered end-to-end in spec/integration_spec.rb.
RSpec.describe Jekyll::MarkdownOutput::MarkdownPage do
  let(:tmpsrc) { Dir.mktmpdir("jmo-src-") }
  after { FileUtils.rm_rf(tmpsrc) }

  def site_double(extra = {})
    instance_double(
      Jekyll::Site,
      dest: "/dest",
      source: tmpsrc,
      config: { "url" => "https://example.com" }.merge(extra),
    )
  end

  # Write a source file under tmpsrc and return its absolute path.
  def write_source(rel_path, body)
    abs = File.join(tmpsrc, rel_path)
    FileUtils.mkdir_p(File.dirname(abs))
    File.write(abs, body)
    abs
  end

  # Build a doc double over a real source file. Defaults set
  # `render_with_liquid: false` so to_s skips the Liquid pipeline.
  def make_doc(url:, data: {}, source_body: "Body.\n", source_rel: "_posts/2024-01-01-x.md")
    abs = write_source(source_rel, source_body)
    merged = { "render_with_liquid" => false }.merge(data)
    instance_double("Jekyll::Document", url: url, data: merged, path: abs).tap do |d|
      allow(d).to receive(:to_liquid).and_return({})
      allow(d).to receive(:relative_path).and_return(source_rel)
    end
  end

  # Pull the YAML frontmatter block out of the rendered output.
  def parse_frontmatter(output)
    m = output.match(/\A---\n(.*?)\n---/m)
    m && YAML.safe_load(m[1], permitted_classes: [Date, Time, Symbol])
  end

  let(:default_options) do
    {
      "extension"             => ".md",
      "include_title_heading" => true,
      "frontmatter_keys"      => Jekyll::MarkdownOutput::MarkdownPage::DEFAULT_FRONTMATTER_KEYS,
    }
  end

  describe "#relative_destination" do
    {
      "/foo"          => "/foo.md",
      "/foo.html"     => "/foo.md",
      "/a/b/foo.html" => "/a/b/foo.md",
      "/foo/"         => "/foo/index.md",
      "/"             => "/index.md",
    }.each do |url, expected|
      it "maps #{url.inspect} to #{expected.inspect}" do
        page = described_class.new(site_double, make_doc(url: url), default_options)
        expect(page.relative_destination).to eq(expected)
      end
    end

    it "honors a custom extension option" do
      page = described_class.new(site_double, make_doc(url: "/foo"), default_options.merge("extension" => ".txt"))
      expect(page.relative_destination).to eq("/foo.txt")
    end
  end

  describe "#destination" do
    it "joins the site dest with the relative destination" do
      page = described_class.new(site_double, make_doc(url: "/foo"), default_options)
      expect(page.destination).to eq("/dest/foo.md")
    end
  end

  describe "#source_file?" do
    it "returns true for a disk-backed source" do
      page = described_class.new(site_double, make_doc(url: "/foo"), default_options)
      expect(page.source_file?).to eq(true)
    end

    it "returns false for a generated page without a source file" do
      doc = instance_double("Jekyll::Page", path: "redirect.html")
      page = described_class.new(site_double, doc, default_options)
      expect(page.source_file?).to eq(false)
    end
  end

  describe "frontmatter generation" do
    it "includes title, url, summary, tags, category, author when set" do
      d = make_doc(url: "/foo", data: {
        "title"    => "Hello",
        "summary"  => "A summary.",
        "tags"     => %w[a b],
        "category" => "life",
        "author"   => "Abhinav",
      })
      data = parse_frontmatter(described_class.new(site_double, d, default_options).to_s)
      expect(data).to include(
        "title"    => "Hello",
        "url"      => "https://example.com/foo",
        "summary"  => "A summary.",
        "tags"     => %w[a b],
        "category" => "life",
        "author"   => "Abhinav",
      )
    end

    it "prepends site url to relative URLs" do
      d = make_doc(url: "/foo", data: { "title" => "T" })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["url"]).to eq("https://example.com/foo")
    end

    it "does not prepend site url to already-absolute URLs" do
      d = make_doc(url: "https://other.example/foo", data: { "title" => "T" })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["url"]).to eq("https://other.example/foo")
    end

    it "drops keys whose values are nil or empty" do
      d = make_doc(url: "/foo", data: { "title" => "Only Title" })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out).keys).to contain_exactly("title", "url")
    end

    it "respects a custom frontmatter_keys allowlist" do
      d = make_doc(url: "/foo", data: { "title" => "T", "tags" => %w[x], "author" => "A" })
      out = described_class.new(site_double, d, default_options.merge("frontmatter_keys" => %w[title tags])).to_s
      expect(parse_frontmatter(out).keys).to contain_exactly("title", "tags")
    end

    it "rejects empty string tags" do
      d = make_doc(url: "/foo", data: { "title" => "T", "tags" => ["a", "", "b"] })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["tags"]).to eq(%w[a b])
    end

    it "falls back to site author when document author is missing" do
      site = site_double("author" => "Site Author")
      d = make_doc(url: "/foo", data: { "title" => "T" })
      out = described_class.new(site, d, default_options).to_s
      expect(parse_frontmatter(out)["author"]).to eq("Site Author")
    end

    it "ISO 8601-formats Time-like dates" do
      time = Time.utc(2024, 1, 1, 9, 0, 0)
      d = make_doc(url: "/foo", data: { "title" => "T", "date" => time })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["date"]).to eq(time.iso8601)
    end

    it "handles dates that don't respond to iso8601 by falling back to to_s" do
      d = make_doc(url: "/foo", data: { "title" => "T", "date" => "2024-01-01" })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["date"]).to eq("2024-01-01")
    end

    it "does not emit a frontmatter block when no keys are populated" do
      d = make_doc(url: "/foo", data: {})
      page = described_class.new(site_double, d, default_options.merge("frontmatter_keys" => %w[summary tags]))
      expect(page.to_s).not_to start_with("---")
    end
  end

  describe "summary fallback to excerpt" do
    it "uses an excerpt that responds to .content as plain text" do
      excerpt = double(content: "<p>Excerpted body.</p>\n")
      d = make_doc(url: "/foo", data: { "title" => "T", "excerpt" => excerpt })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["summary"]).to eq("Excerpted body.")
    end

    it "uses a plain-string excerpt directly" do
      d = make_doc(url: "/foo", data: { "title" => "T", "excerpt" => "Plain excerpt." })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["summary"]).to eq("Plain excerpt.")
    end

    it "strips HTML tags when falling back to excerpt" do
      excerpt = double(content: "<p>Bold <strong>here</strong>.</p>")
      d = make_doc(url: "/foo", data: { "title" => "T", "excerpt" => excerpt })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["summary"]).to eq("Bold here.")
    end

    it "does not include summary when excerpt is empty" do
      excerpt = double(content: "")
      d = make_doc(url: "/foo", data: { "title" => "T", "excerpt" => excerpt })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)).not_to have_key("summary")
    end

    it "prefers an explicit frontmatter summary over the excerpt" do
      excerpt = double(content: "Excerpt text.")
      d = make_doc(url: "/foo", data: { "title" => "T", "summary" => "Explicit.", "excerpt" => excerpt })
      out = described_class.new(site_double, d, default_options).to_s
      expect(parse_frontmatter(out)["summary"]).to eq("Explicit.")
    end

    it "never serializes a Ruby object graph into YAML" do
      # Simulates the Jekyll::Excerpt-shaped object that previously caused a
      # giant !ruby/object dump in the frontmatter.
      excerpt = double(content: "Real excerpt body.")
      d = make_doc(url: "/foo", data: { "title" => "T", "excerpt" => excerpt })
      out = described_class.new(site_double, d, default_options).to_s
      expect(out).not_to include("!ruby/object")
    end
  end

  describe "body output" do
    it "prepends a # Title heading when include_title_heading is true" do
      d = make_doc(url: "/foo", data: { "title" => "Hello" }, source_body: "---\ntitle: Hello\n---\n\nBody text.")
      out = described_class.new(site_double, d, default_options).to_s
      expect(out).to include("# Hello\n")
      expect(out).to include("Body text.")
    end

    it "omits the title heading when include_title_heading is false" do
      d = make_doc(url: "/foo", data: { "title" => "Hello" }, source_body: "---\ntitle: Hello\n---\n\nBody text.")
      out = described_class.new(site_double, d, default_options.merge("include_title_heading" => false)).to_s
      expect(out).not_to include("# Hello")
      expect(out).to include("Body text.")
    end

    it "uses the source body, stripping any frontmatter block" do
      d = make_doc(url: "/foo", data: { "title" => "T" }, source_body: "---\ntitle: T\n---\n\nOnly body.")
      out = described_class.new(site_double, d, default_options).to_s
      expect(out).to include("Only body.")
      # Only the emitted YAML fences appear (open + close).
      expect(out.scan(/^---\s*$/).length).to eq(2)
    end

    it "handles a source file without a frontmatter block" do
      d = make_doc(url: "/foo", data: { "title" => "T" }, source_body: "Just body, no frontmatter.")
      out = described_class.new(site_double, d, default_options).to_s
      expect(out).to include("Just body, no frontmatter.")
    end

    it "ends with a single trailing newline" do
      d = make_doc(url: "/foo", data: { "title" => "T" }, source_body: "---\ntitle: T\n---\n\nBody.")
      out = described_class.new(site_double, d, default_options).to_s
      expect(out).to end_with("\n")
      expect(out).not_to end_with("\n\n")
    end

    it "reads the source as UTF-8 even when the locale is ASCII" do
      d = make_doc(url: "/foo", data: { "title" => "Café" }, source_body: "---\ntitle: Café\n---\n\nNoël ☃")
      out = described_class.new(site_double, d, default_options).to_s
      expect(out.encoding).to eq(Encoding::UTF_8)
      expect(out).to include("Noël ☃")
    end

    it "converts rendered HTML source to GitHub-flavored Markdown when enabled" do
      d = make_doc(
        url: "/contact.html",
        data: { "title" => "Contact" },
        source_rel: "contact.HTML",
        source_body: "---\ntitle: Contact\n---\n\n<p>Hello <strong>world</strong>.</p>\n<pre><code>puts 'hi'</code></pre>",
      )
      options = default_options.merge("html_to_markdown" => true)
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("Hello **world**.")
      expect(out).to include("```\nputs 'hi'\n```")
      expect(out).not_to include("<p>")
    end

    it "adds the required space after the heading marker for details summaries" do
      d = make_doc(
        url: "/faq.html",
        source_rel: "faq.html",
        source_body: <<~HTML,
          <details>
            <summary>What if none of these plans fit my budget?</summary>
            <p>Contact us.</p>
          </details>
        HTML
      )
      options = default_options.merge("html_to_markdown" => true)
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("# What if none of these plans fit my budget?\n\nContact us.")
      expect(out).not_to include("#What if none of these plans fit my budget?")
    end

    it "leaves HTML source unchanged when conversion is disabled" do
      d = make_doc(
        url: "/contact.html",
        source_rel: "contact.htm",
        source_body: "<p>Hello <strong>world</strong>.</p>",
      )
      out = described_class.new(site_double, d, default_options.merge("html_to_markdown" => false)).to_s

      expect(out).to include("<p>Hello <strong>world</strong>.</p>")
    end

    it "passes configured conversion options to reverse_markdown" do
      d = make_doc(
        url: "/custom.html",
        source_rel: "custom.html",
        source_body: "<custom-element>Hello <strong>world</strong>.</custom-element>",
      )
      options = default_options.merge(
        "html_to_markdown" => true,
        "html_to_markdown_options" => { "unknown_tags" => "bypass" },
      )
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("Hello **world**.")
      expect(out).not_to include("custom-element")
    end

    it "uses SVG and i aria-labels as text when enabled" do
      d = make_doc(
        url: "/features.html",
        source_rel: "features.html",
        source_body: <<~HTML,
          <p><a href="/plans"><svg aria-label="Included"><path d="M0 0" /></svg></a></p>
          <p><i class="status" aria-label="Unavailable"></i></p>
        HTML
      )
      options = default_options.merge(
        "html_to_markdown" => true,
        "include_aria_labels" => true,
        "html_to_markdown_options" => { "unknown_tags" => "bypass" },
      )
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("[Included](/plans)")
      expect(out).to include("Unavailable")
      expect(out).not_to include("<svg")
      expect(out).not_to include("<i")
    end

    it "does not expose aria-labels from non-SVG elements" do
      d = make_doc(
        url: "/features.html",
        source_rel: "features.html",
        source_body: '<span aria-label="Not included"></span><i aria-label="Included"></i>',
      )
      options = default_options.merge(
        "html_to_markdown" => true,
        "include_aria_labels" => true,
        "html_to_markdown_options" => { "unknown_tags" => "bypass" },
      )
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("Included")
      expect(out).not_to include("Not included")
    end

    it "ignores blank SVG aria-labels" do
      d = make_doc(
        url: "/features.html",
        source_rel: "features.html",
        source_body: '<p>Before<svg aria-label="  "></svg>after</p>',
      )
      options = default_options.merge(
        "html_to_markdown" => true,
        "include_aria_labels" => true,
        "html_to_markdown_options" => { "unknown_tags" => "bypass" },
      )
      out = described_class.new(site_double, d, options).to_s

      expect(out).to include("Beforeafter")
    end
  end
end
