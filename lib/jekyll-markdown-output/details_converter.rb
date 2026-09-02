# frozen_string_literal: true

module Jekyll
  module MarkdownOutput
    # reverse_markdown 3.x emits GitHub-flavored <details> blocks with a
    # leading "#" immediately followed by the summary text. Markdown headings
    # require a space after the marker, so correct that converter while
    # preserving its handling of the block's remaining content.
    class DetailsConverter < ReverseMarkdown::Converters::Details
      def convert(node, state = {})
        super.sub(/\A#(?=\S)/, "# ")
      end
    end
  end
end

details_converter = Jekyll::MarkdownOutput::DetailsConverter.new
ReverseMarkdown::Converters.register(:details, details_converter)
ReverseMarkdown::Converters.register(:summary, details_converter)
