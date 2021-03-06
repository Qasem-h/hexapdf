# -*- encoding: utf-8 -*-
#
#--
# This file is part of HexaPDF.
#
# HexaPDF - A Versatile PDF Creation and Manipulation Library For Ruby
# Copyright (C) 2016 Thomas Leitner
#
# HexaPDF is free software: you can redistribute it and/or modify it
# under the terms of the GNU Affero General Public License version 3 as
# published by the Free Software Foundation with the addition of the
# following permission added to Section 15 as permitted in Section 7(a):
# FOR ANY PART OF THE COVERED WORK IN WHICH THE COPYRIGHT IS OWNED BY
# THOMAS LEITNER, THOMAS LEITNER DISCLAIMS THE WARRANTY OF NON
# INFRINGEMENT OF THIRD PARTY RIGHTS.
#
# HexaPDF is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE. See the GNU Affero General Public
# License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with HexaPDF. If not, see <http://www.gnu.org/licenses/>.
#
# The interactive user interfaces in modified source and object code
# versions of HexaPDF must display Appropriate Legal Notices, as required
# under Section 5 of the GNU Affero General Public License version 3.
#
# In accordance with Section 7(b) of the GNU Affero General Public
# License, a covered work must retain the producer line in every PDF that
# is created or manipulated using HexaPDF.
#++

require 'hexapdf/font/type1'
require 'hexapdf/font/encoding'
require 'hexapdf/error'

module HexaPDF
  module Font

    # This class wraps a generic Type1 font object and provides the methods needed for working with
    # the font in a PDF context.
    class Type1Wrapper

      # Represents a single glyph of the wrapped font.
      class Glyph

        # The name of the glyph.
        attr_reader :name
        alias_method :id, :name

        # Creates a new Glyph object.
        def initialize(font, name)
          @font = font
          @name = name
        end

        # Returns the width of the glyph.
        def width
          @width ||= @font.width(name)
        end

        # Returns +true+ if the glyph represents the space character.
        def space?
          @name == :space
        end

      end

      private_constant :Glyph


      # Returns the wrapped Type1 font object.
      attr_reader :wrapped_font

      # The PDF font dictionary representing the wrapped font.
      attr_reader :dict

      # Creates a new object wrapping the Type1 font for the PDF document.
      #
      # The optional argument +custom_encoding+ can be set to +true+ so that a custom encoding
      # instead of the WinAnsiEncoding is used.
      def initialize(document, font, custom_encoding: false)
        @document = document
        @wrapped_font = font

        @dict = build_font_dict
        @document.register_listener(:complete_objects, &method(:complete_font_dict))
        if @wrapped_font.metrics.character_set == 'Special' || custom_encoding
          @encoding = Encoding::Base.new
          @encoding.code_to_name[32] = :space
          @max_code = 32 # 32 = space
        else
          @encoding = Encoding.for_name(:WinAnsiEncoding)
          @max_code = 255 # Encoding is not modified
        end

        @zapf_dingbats_opt = {zapf_dingbats: (@wrapped_font.font_name == 'ZapfDingbats')}
        @name_to_glyph = {}
        @codepoint_to_glyph = {}
        @encoded_glyphs = {}
      end

      # Returns a Glyph object for the given glyph name.
      def glyph(name)
        @name_to_glyph[name] ||=
          begin
            unless @wrapped_font.metrics.character_metrics.key?(name)
              name = @document.config['font.on_missing_glyph'].call(name, @wrapped_font)
            end
            Glyph.new(@wrapped_font, name)
          end
      end

      # Returns an array of glyph objects representing the characters in the UTF-8 encoded string.
      def decode_utf8(str)
        str.each_codepoint.map do |c|
          @codepoint_to_glyph[c] ||=
            begin
              name = Encoding::GlyphList.unicode_to_name('' << c, @zapf_dingbats_opt)
              name = '' << c if name == :'.notdef'
              glyph(name)
            end
        end
      end

      # Encodes the glyph and returns the code string.
      def encode(glyph)
        @encoded_glyphs[glyph.name] ||=
          begin
            code = @encoding.code_to_name.key(glyph.name)
            if code
              code.chr.freeze
            elsif @max_code < 255
              @max_code += 1
              @encoding.code_to_name[@max_code] = glyph.name
              @max_code.chr.freeze
            else
              raise HexaPDF::Error, "Type1 encoding has no codepoint for #{glyph.name}"
            end
          end
      end

      private

      # Builds a generic Type1 font dictionary for the wrapped font.
      #
      # Generic in the sense that no information regarding the encoding or widths is included.
      def build_font_dict
        unless defined?(@fd)
          @fd = @document.wrap(Type: :FontDescriptor,
                               FontName: @wrapped_font.font_name.intern,
                               FontBBox: @wrapped_font.bounding_box,
                               ItalicAngle: @wrapped_font.italic_angle || 0,
                               Ascent: @wrapped_font.ascender || 0,
                               Descent: @wrapped_font.descender || 0,
                               CapHeight: @wrapped_font.cap_height,
                               XHeight: @wrapped_font.x_height,
                               StemH: @wrapped_font.dominant_horizontal_stem_width,
                               StemV: @wrapped_font.dominant_vertical_stem_width || 0)
          @fd.flag(:fixed_pitch) if @wrapped_font.metrics.is_fixed_pitch
          @fd.flag(@wrapped_font.metrics.character_set == 'Special' ? :symbolic : :nonsymbolic)
          @fd.must_be_indirect = true
        end

        @document.wrap(Type: :Font, Subtype: :Type1,
                       BaseFont: @wrapped_font.font_name.intern, Encoding: :WinAnsiEncoding,
                       FontDescriptor: @fd)
      end

      # Array of valid encoding names in PDF
      VALID_ENCODING_NAMES = [:WinAnsiEncoding, :MacRomanEncoding, :MacExpertEncoding]

      # Completes the font dictionary by filling in the values that depend on the used encoding.
      def complete_font_dict
        min, max = @encoding.code_to_name.keys.minmax
        @dict[:FirstChar] = min
        @dict[:LastChar] = max
        @dict[:Widths] = (min..max).map {|code| glyph(@encoding.name(code)).width}

        if VALID_ENCODING_NAMES.include?(@encoding.encoding_name)
          @dict[:Encoding] = @encoding.encoding_name
        else
          differences = [min]
          (min..max).each {|code| differences << @encoding.name(code)}
          @dict[:Encoding] = {Differences: differences}
        end
      end

    end

  end
end
