#!/usr/bin/env -S jq --args -sRf

def is_void_element(tag):
	["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"] 
	| index(tag | ascii_downcase) | not | not;

def xml_unescape:
	gsub("&amp;"; "&") | gsub("&lt;"; "<") | gsub("&gt;"; ">") | gsub("&quot;"; "\"");

def parse_attrs:
	[ scan("\\s+([a-zA-Z0-9:-]+)(?:\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]*)))?"; "si") ]
	| map({
			key: (.[0] | ascii_downcase),
			value: (.[1] // .[2] // .[3] // "")
		})
	| if length == 0 then {} else from_entries end;

def tokenize:
	[
		scan(
			"<\\s*(?:script|style)[^>]*>[\\s\\S]*?</\\s*(?:script|style)\\s*>|" +
			"<!\\[CDATA\\[[\\s\\S]*?\\]\\]>|" +
			"<!--[\\s\\S]*?-->|" +
			"<!DOCTYPE[^>]*>|" +
			"<\\?.*?\\?>|" +
			"</?\\s*[a-zA-Z0-9:-]+(?:\\s+[a-zA-Z0-9:-]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]*))?)*\\s*/?>|" +
			"[^<]+";
			"si"
		)
	] | map(
			select(test("^\\s*$") | not)
			| select(test("^<!--") | not)
			| select(test("^<\\?") | not)
			| select(test("^<!DOCTYPE") | not)
		);

def to_jsonml:
	. as $node
	| ($node.attrs // {}) as $attrs
	| ($node.children // []) as $children
	| if ($attrs | length) == 0 and ($children | length) == 0 then
			[$node.name]
		elif ($children | length) == 0 then
			[$node.name, $attrs]
		else
			[$node.name, $attrs, $children]
		end;

def parse_tokens:
	reduce .[] as $token (
		{ stack: [] };
		if ($token | test("^</")) then
			($token | match("^</\\s*([a-zA-Z0-9:-]+)"; "si").captures[0].string | ascii_downcase) as $close_tag
			| .stack as $s
			| ($s | to_entries | map(select(.value.name == $close_tag)) | last | .key) as $match_idx
			| if $match_idx != null then
					$s[$match_idx] | to_jsonml as $jsonml
					| if $match_idx > 0 then
							.stack = $s[0:$match_idx] 
							| .stack[-1].children += [$jsonml]
						else
							.stack = [$jsonml]
						end
				else . end
		elif ($token | test("^<\\s*script"; "i")) then
			($token | match("^<\\s*script([^>]*)>([\\s\\S]*)</\\s*script\\s*>$"; "si")) as $m
			| if $m then
					("script") as $tag
					| ($m.captures[0].string | parse_attrs) as $attrs
					| ($m.captures[1].string) as $content
					| ({ name: $tag, attrs: $attrs, children: (if $content != "" then [$content] else [] end) } | to_jsonml) as $jsonml
					| if (.stack | length) > 0 then
							.stack[-1].children += [$jsonml]
						else
							.stack += [$jsonml]
						end
				else . end
		elif ($token | test("^<\\s*style"; "i")) then
			($token | match("^<\\s*style([^>]*)>([\\s\\S]*)</\\s*style\\s*>$"; "si")) as $m
			| if $m then
					("style") as $tag
					| ($m.captures[0].string | parse_attrs) as $attrs
					| ($m.captures[1].string) as $content
					| ({ name: $tag, attrs: $attrs, children: (if $content != "" then [$content] else [] end) } | to_jsonml) as $jsonml
					| if (.stack | length) > 0 then
							.stack[-1].children += [$jsonml]
						else
							.stack += [$jsonml]
						end
				else . end
		elif ($token | startswith("<![CDATA[")) then
			($token[9:-3]) as $cdata_text
			| if $cdata_text != "" and (.stack | length) > 0 then
					.stack[-1].children += [$cdata_text]
				else . end
		elif ($token | startswith("<")) and ($token | endswith("/>")) then
			($token | match("^</?\\s*([a-zA-Z0-9:-]+)"; "si").captures[0].string | ascii_downcase) as $tag
			| ($token | parse_attrs) as $attrs
			| ({ name: $tag, attrs: $attrs, children: [] } | to_jsonml) as $jsonml
			| if (.stack | length) > 0 then
					.stack[-1].children += [$jsonml]
				else
					.stack += [$jsonml]
				end
		elif ($token | startswith("<")) then
			($token | match("^</?\\s*([a-zA-Z0-9:-]+)"; "si").captures[0].string | ascii_downcase) as $tag
			| ($token | parse_attrs) as $attrs
			| if is_void_element($tag) then
					({ name: $tag, attrs: $attrs, children: [] } | to_jsonml) as $jsonml
					| if (.stack | length) > 0 then
							.stack[-1].children += [$jsonml]
						else
							.stack += [$jsonml]
						end
				else
					.stack += [{ name: $tag, attrs: $attrs, children: [] }]
				end
		else
			if $token != "" and (.stack | length) > 0 then
				.stack[-1].children += [$token]
			else . end
		end
	) | .stack[0];

#def fromhtml:
tokenize | parse_tokens
