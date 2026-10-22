#!/usr/bin/env -S jq --args -sRf

def parse_attrs:
	[ scan("([a-zA-Z0-9:-]+)\\s*=\\s*(?:\"([^\"]*)\"|'([^']*)'|([^\\s>]*))"; "s") ]
	| map({
			key: .[0],
			value: (.[1] // .[2] // .[3])
		})
	| if length == 0 then {} else from_entries end;

def tokenize:
	[
		scan(
			"<!\\[CDATA\\[.*?\\]\\]>|" +
			"<!--.*?-->|" +
			"<!DOCTYPE[^>]*>|" +
			"<\\?.*?\\?>|" +
			"</?[a-zA-Z0-9:-]+(?:\\s+[a-zA-Z0-9:-]+(?:\\s*=\\s*(?:\"[^\"]*\"|'[^']*'|[^\\s>]*))?)*\\s*/?>|" +
			"[^<]+";
			"s"
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
		if ($token | startswith("</")) then
			.stack as $s
			| ($s | length) as $len
			| if $len > 1 then
					$s[-1] | to_jsonml as $jsonml
					| .stack = $s[0:-2] + [$s[-2] | .children += [$jsonml]]
				elif $len == 1 then
					$s[-1] | to_jsonml as $jsonml
					| .stack = [$jsonml]
				else . end
		elif ($token | startswith("<![CDATA[")) then
			($token[9:-3]) as $cdata_text
			| if $cdata_text != "" and (.stack | length) > 0 then
					.stack[-1].children += [$cdata_text]
				else . end
		elif ($token | startswith("<")) and ($token | endswith("/>")) then
			($token | match("^</?([a-zA-Z0-9:-]+)"; "s").captures[0].string) as $tag
			| ($token | parse_attrs) as $attrs
			| ({ name: $tag, attrs: $attrs, children: [] } | to_jsonml) as $jsonml
			| if (.stack | length) > 0 then
					.stack[-1].children += [$jsonml]
				else . end
		elif ($token | startswith("<")) then
			($token | match("^</?([a-zA-Z0-9:-]+)"; "s").captures[0].string) as $tag
			| ($token | parse_attrs) as $attrs
			| .stack += [{ name: $tag, attrs: $attrs, children: [] }]
		else
			if $token != "" and (.stack | length) > 0 then
				.stack[-1].children += [$token]
			else . end
		end
	) | .stack[0];

tokenize | parse_tokens