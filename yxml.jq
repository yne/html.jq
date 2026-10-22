#!/usr/bin/env -S jq --args -sRf
# XML to JSONML, based on dev.yorhel.nl/yxml => no Regexp needed

# ---------- character classifiers ----------
def isSP($c): $c == 32 or $c == 9 or $c == 10;
def isAlpha($c): ($c >= 65 and $c <= 90) or ($c >= 97 and $c <= 122);
def isNum($c): $c >= 48 and $c <= 57;
def isHex($c): isNum($c) or ($c >= 65 and $c <= 70) or ($c >= 97 and $c <= 102);
def isEncName($c): isAlpha($c) or isNum($c) or $c == 46 or $c == 95 or $c == 45;
def isNameStart($c): isAlpha($c) or $c == 58 or $c == 95 or $c >= 128;
def isName($c): isNameStart($c) or isNum($c) or $c == 45 or $c == 46;
def isRef($c): isNum($c) or isAlpha($c) or $c == 35;
def isAttValue($c; $quote): $c != $quote and $c != 60 and $c != 38;

# ---------- stack helpers ----------
def topname($x): $x.stack[-1];
def topstr($x): (topname($x) | implode);
def pushname($x; $c): $x + {stack: ($x.stack + [[$c]])};
def appendname($x; $c):
	$x + {stack: ($x.stack[0:-1] + [((topname($x)) + [$c])])};
def popname($x): $x + {stack: ($x.stack[0:-1])};

# ---------- PI name check ----------
def isXmlName($n):
	($n | length) == 3
	and ($n[0] == 120 or $n[0] == 88)
	and ($n[1] == 109 or $n[1] == 77)
	and ($n[2] == 108 or $n[2] == 76);

def pistart_tok($x):
	(topname($x)) as $n
	| if isXmlName($n) then error("yxml: syntax error (PI name xml)")
		else {t:"pistart", name: ($n | implode)} end;

# ---------- entity / character references ----------
def hexval($c):
	if $c <= 57 then $c - 48
	elif $c <= 70 then $c - 55
	else $c - 87 end;

def decode_ref($d):
	if ($d | length) == 0 then null
	elif $d[0] == 35 then
		if ($d | length) >= 2 and $d[1] == 120 then
			(reduce ($d[2:][]) as $c ({ch:0, ok:true};
				 if isHex($c) then {ch: ((.ch * 16) + hexval($c)), ok:true}
				 else {ch: .ch, ok:false} end)) as $r
			| if $r.ok then $r.ch else null end
		else
			(reduce ($d[1:][]) as $c ({ch:0, ok:true};
				 if isNum($c) then {ch: ((.ch * 10) + ($c - 48)), ok:true}
				 else {ch: .ch, ok:false} end)) as $r
			| if $r.ok then $r.ch else null end
		end
	else
		if $d == [108,116] then 60
		elif $d == [103,116] then 62
		elif $d == [97,109,112] then 38
		elif $d == [97,112,111,115] then 39
		elif $d == [113,117,111,116] then 34
		else null end
	end;

def refadd($x; $c):
	if $x.reflen >= 7 then error("yxml: reference too long")
	else $x + {reflen: ($x.reflen + 1), data: ($x.data + [$c])} end;

def refend($x; $kind):
	(decode_ref($x.data)) as $p
	| if $p == null or $p == 0 or $p > 1114111 or $p == 65534 or $p == 65535 or ($p >= 57343 and $p <= 59389)
		then error("yxml: invalid character reference")
		else {x: ($x + {data: [], reflen: 0}), tok: {t:$kind, data: ([$p] | implode)}}
		end;

# ---------- element close helpers ----------
def selfclose($x):
	(popname($x)) as $y
	| if ($y.stack | length) > 0 then $y + {elem_pos: 0}
		else $y + {state: "misc3", elem_pos: 0} end;

def elemclose($x; $c):
	(topname($x)) as $name
	| if $x.elem_pos < ($name | length) and $name[$x.elem_pos] == $c then
			$x + {elem_pos: ($x.elem_pos + 1)}
		elif $x.strict then error("yxml: close tag does not match")
		else $x + {elem_pos: ($x.elem_pos + 1)} end;

def elemcloseend($x):
	if $x.strict and $x.elem_pos != (topname($x) | length) then
		error("yxml: close tag does not match")
	else selfclose($x) end;

# ---------- one-byte state-machine step ----------
def dispatch($x; $c):
	if $x.state == "string" then
		if $c == $x.string[$x.strpos] then
			if ($x.strpos + 1) == ($x.string | length) then
				{x: ($x + {state: $x.nextstate, string: [], strpos: 0}), tok: null}
			else
				{x: ($x + {strpos: ($x.strpos + 1)}), tok: null}
			end
		else error("yxml: syntax error (literal)") end

	elif $x.state == "attr0" then
		if isName($c) then {x: appendname($x; $c), tok: null}
		elif isSP($c) then {x: ($x + {state:"attr1"}), tok: {t:"attrstart", name: topstr($x)}}
		elif $c == 61 then {x: ($x + {state:"attr2"}), tok: {t:"attrstart", name: topstr($x)}}
		else error("yxml: syntax error (attr0)") end

	elif $x.state == "attr1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 61 then {x: ($x + {state:"attr2"}), tok: null}
		else error("yxml: syntax error (attr1)") end

	elif $x.state == "attr2" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 39 or $c == 34 then {x: ($x + {state:"attr3", quote:$c}), tok: null}
		else error("yxml: syntax error (attr2)") end

	elif $x.state == "attr3" then
		if isAttValue($c; $x.quote) then
			{x: $x, tok: {t:"attrval", data: ([(if $c == 9 or $c == 10 then 32 else $c end)] | implode)}}
		elif $c == 38 then {x: ($x + {state:"attr4", reflen:0, data:[]}), tok: null}
		elif $c == $x.quote then {x: (popname($x) + {state:"elem2"}), tok: {t:"attrend"}}
		else error("yxml: syntax error (attr3)") end

	elif $x.state == "attr4" then
		if isRef($c) then {x: refadd($x; $c), tok: null}
		elif $c == 59 then (refend($x; "attrval")) as $r
			| {x: ($r.x + {state:"attr3"}), tok: $r.tok}
		else error("yxml: syntax error (attr4)") end

	elif $x.state == "cd0" then
		if $c == 93 then {x: ($x + {state:"cd1"}), tok: null}
		else {x: $x, tok: {t:"content", data: ([$c] | implode)}} end

	elif $x.state == "cd1" then
		if $c == 93 then {x: ($x + {state:"cd2"}), tok: null}
		else {x: ($x + {state:"cd0"}), tok: {t:"content", data: ([93, $c] | implode)}} end

	elif $x.state == "cd2" then
		if $c == 93 then {x: $x, tok: {t:"content", data: "]"}}
		elif $c == 62 then {x: ($x + {state:"misc2"}), tok: null}
		else {x: ($x + {state:"cd0"}), tok: {t:"content", data: ([93,93,$c] | implode)}} end

	elif $x.state == "comment0" then
		if $c == 45 then {x: ($x + {state:"comment1"}), tok: null}
		else error("yxml: syntax error (comment0)") end

	elif $x.state == "comment1" then
		if $c == 45 then {x: ($x + {state:"comment2"}), tok: null}
		else error("yxml: syntax error (comment1)") end

	elif $x.state == "comment2" then
		if $c == 45 then {x: ($x + {state:"comment3"}), tok: null}
		else {x: $x, tok: null} end

	elif $x.state == "comment3" then
		if $c == 45 then {x: ($x + {state:"comment4"}), tok: null}
		else {x: ($x + {state:"comment2"}), tok: null} end

	elif $x.state == "comment4" then
		if $c == 62 then {x: ($x + {state: $x.nextstate}), tok: null}
		else error("yxml: syntax error (comment4)") end

	elif $x.state == "dt0" then
		if $c == 62 then {x: ($x + {state:"misc1"}), tok: null}
		elif $c == 39 or $c == 34 then {x: ($x + {state:"dt1", quote:$c, nextstate:"dt0"}), tok: null}
		elif $c == 60 then {x: ($x + {state:"dt2"}), tok: null}
		else {x: $x, tok: null} end

	elif $x.state == "dt1" then
		if $c == $x.quote then {x: ($x + {state:$x.nextstate}), tok: null}
		else {x: $x, tok: null} end

	elif $x.state == "dt2" then
		if $c == 63 then {x: ($x + {state:"pi0", nextstate:"dt0"}), tok: null}
		elif $c == 33 then {x: ($x + {state:"dt3"}), tok: null}
		else error("yxml: syntax error (dt2)") end

	elif $x.state == "dt3" then
		if $c == 45 then {x: ($x + {state:"comment1", nextstate:"dt0"}), tok: null}
		else {x: ($x + {state:"dt4"}), tok: null} end

	elif $x.state == "dt4" then
		if $c == 39 or $c == 34 then {x: ($x + {state:"dt1", quote:$c, nextstate:"dt4"}), tok: null}
		elif $c == 62 then {x: ($x + {state:"dt0"}), tok: null}
		else {x: $x, tok: null} end

	elif $x.state == "elem0" then
		if isName($c) then {x: appendname($x; $c), tok: null}
		elif isSP($c) then {x: ($x + {state:"elem1", elem_pos:0}), tok: {t:"elemstart", name: topstr($x)}}
		elif $c == 47 then {x: ($x + {state:"elem3", elem_pos:0}), tok: {t:"elemstart", name: topstr($x)}}
		elif $c == 62 then {x: ($x + {state:"misc2", elem_pos:0}), tok: {t:"elemstart", name: topstr($x)}}
		else error("yxml: syntax error (elem0)") end

	elif $x.state == "elem1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 47 then {x: ($x + {state:"elem3"}), tok: null}
		elif $c == 62 then {x: ($x + {state:"misc2"}), tok: null}
		elif isNameStart($c) then {x: (pushname($x; $c) + {state:"attr0"}), tok: null}
		else error("yxml: syntax error (elem1)") end

	elif $x.state == "elem2" then
		if isSP($c) then {x: ($x + {state:"elem1"}), tok: null}
		elif $c == 47 then {x: ($x + {state:"elem3"}), tok: null}
		elif $c == 62 then {x: ($x + {state:"misc2"}), tok: null}
		else error("yxml: syntax error (elem2)") end

	elif $x.state == "elem3" then
		if $c == 62 then {x: (($x + {state:"misc2"}) | selfclose(.)), tok: {t:"elemend"}}
		else error("yxml: syntax error (elem3)") end

	elif $x.state == "etag0" then
		if isNameStart($c) then {x: (elemclose($x; $c) + {state:"etag1"}), tok: null}
		else error("yxml: syntax error (etag0)") end

	elif $x.state == "etag1" then
		if isName($c) then {x: elemclose($x; $c), tok: null}
		elif isSP($c) then {x: (($x + {state:"etag2"}) | elemcloseend(.)), tok: {t:"elemend"}}
		elif $c == 62 then {x: (($x + {state:"misc2"}) | elemcloseend(.)), tok: {t:"elemend"}}
		else error("yxml: syntax error (etag1)") end

	elif $x.state == "etag2" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 62 then {x: ($x + {state:"misc2"}), tok: null}
		else error("yxml: syntax error (etag2)") end

	elif $x.state == "enc0" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 61 then {x: ($x + {state:"enc1"}), tok: null}
		else error("yxml: syntax error (enc0)") end

	elif $x.state == "enc1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 39 or $c == 34 then {x: ($x + {state:"enc2", quote:$c}), tok: null}
		else error("yxml: syntax error (enc1)") end

	elif $x.state == "enc2" then
		if isAlpha($c) then {x: ($x + {state:"enc3"}), tok: null}
		else error("yxml: syntax error (enc2)") end

	elif $x.state == "enc3" then
		if isEncName($c) then {x: $x, tok: null}
		elif $c == $x.quote then {x: ($x + {state:"xmldecl6"}), tok: null}
		else error("yxml: syntax error (enc3)") end

	elif $x.state == "init" then
		if $c == 65279 then {x: ($x + {state:"misc0"}), tok: null}
		elif isSP($c) then {x: ($x + {state:"misc0"}), tok: null}
		elif $c == 60 then {x: ($x + {state:"le0"}), tok: null}
		else error("yxml: syntax error (init)") end

	elif $x.state == "le0" then
		if $c == 33 then {x: ($x + {state:"lee1"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"leq0"}), tok: null}
		elif isNameStart($c) then {x: (pushname($x; $c) + {state:"elem0", elem_pos:0}), tok: null}
		else error("yxml: syntax error (le0)") end

	elif $x.state == "le1" then
		if $c == 33 then {x: ($x + {state:"lee1"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi0", nextstate:"misc1"}), tok: null}
		elif isNameStart($c) then {x: (pushname($x; $c) + {state:"elem0", elem_pos:0}), tok: null}
		else error("yxml: syntax error (le1)") end

	elif $x.state == "le2" then
		if $c == 33 then {x: ($x + {state:"lee2"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi0", nextstate:"misc2"}), tok: null}
		elif $c == 47 then {x: ($x + {state:"etag0", elem_pos:0}), tok: null}
		elif isNameStart($c) then {x: (pushname($x; $c) + {state:"elem0", elem_pos:0}), tok: null}
		else error("yxml: syntax error (le2)") end

	elif $x.state == "le3" then
		if $c == 33 then {x: ($x + {state:"comment0", nextstate:"misc3"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi0", nextstate:"misc3"}), tok: null}
		else error("yxml: syntax error (le3)") end

	elif $x.state == "lee1" then
		if $c == 45 then {x: ($x + {state:"comment1", nextstate:"misc1"}), tok: null}
		elif $c == 68 then {x: ($x + {state:"string", nextstate:"dt0", string:("OCTYPE"|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (lee1)") end

	elif $x.state == "lee2" then
		if $c == 45 then {x: ($x + {state:"comment1", nextstate:"misc2"}), tok: null}
		elif $c == 91 then {x: ($x + {state:"string", nextstate:"cd0", string:("CDATA["|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (lee2)") end

	elif $x.state == "leq0" then
		if $c == 120 then {x: (pushname($x; $c) + {state:"xmldecl0", nextstate:"misc1"}), tok: null}
		elif isNameStart($c) then {x: (pushname($x; $c) + {state:"pi1", nextstate:"misc1"}), tok: null}
		else error("yxml: syntax error (leq0)") end

	elif $x.state == "misc0" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 60 then {x: ($x + {state:"le0"}), tok: null}
		else error("yxml: syntax error (misc0)") end

	elif $x.state == "misc1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 60 then {x: ($x + {state:"le1"}), tok: null}
		else error("yxml: syntax error (misc1)") end

	elif $x.state == "misc2" then
		if $c == 60 then {x: ($x + {state:"le2"}), tok: null}
		elif $c == 38 then {x: ($x + {state:"misc2a", reflen:0, data:[]}), tok: null}
		else {x: $x, tok: {t:"content", data: ([$c] | implode)}} end

	elif $x.state == "misc2a" then
		if isRef($c) then {x: refadd($x; $c), tok: null}
		elif $c == 59 then (refend($x; "content")) as $r
			| {x: ($r.x + {state:"misc2"}), tok: $r.tok}
		else error("yxml: syntax error (misc2a)") end

	elif $x.state == "misc3" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 60 then {x: ($x + {state:"le3"}), tok: null}
		else error("yxml: syntax error (misc3)") end

	elif $x.state == "pi0" then
		if isNameStart($c) then {x: (pushname($x; $c) + {state:"pi1"}), tok: null}
		else error("yxml: syntax error (pi0)") end

	elif $x.state == "pi1" then
		if isName($c) then {x: appendname($x; $c), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi4"}), tok: pistart_tok($x)}
		elif isSP($c) then {x: ($x + {state:"pi2"}), tok: pistart_tok($x)}
		else error("yxml: syntax error (pi1)") end

	elif $x.state == "pi2" then
		if $c == 63 then {x: ($x + {state:"pi3"}), tok: null}
		else {x: $x, tok: {t:"picontent", data: ([$c] | implode)}} end

	elif $x.state == "pi3" then
		if $c == 62 then {x: (popname($x) + {state:$x.nextstate}), tok: {t:"piend"}}
		else {x: ($x + {state:"pi2"}), tok: {t:"picontent", data: ([63, $c] | implode)}} end

	elif $x.state == "pi4" then
		if $c == 62 then {x: (popname($x) + {state:$x.nextstate}), tok: {t:"piend"}}
		else error("yxml: syntax error (pi4)") end

	elif $x.state == "std0" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 61 then {x: ($x + {state:"std1"}), tok: null}
		else error("yxml: syntax error (std0)") end

	elif $x.state == "std1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 39 or $c == 34 then {x: ($x + {state:"std2", quote:$c}), tok: null}
		else error("yxml: syntax error (std1)") end

	elif $x.state == "std2" then
		if $c == 121 then {x: ($x + {state:"string", nextstate:"std3", string:("es"|explode), strpos:0}), tok: null}
		elif $c == 110 then {x: ($x + {state:"string", nextstate:"std3", string:("o"|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (std2)") end

	elif $x.state == "std3" then
		if $c == $x.quote then {x: ($x + {state:"xmldecl8"}), tok: null}
		else error("yxml: syntax error (std3)") end

	elif $x.state == "ver0" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 61 then {x: ($x + {state:"ver1"}), tok: null}
		else error("yxml: syntax error (ver0)") end

	elif $x.state == "ver1" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 39 or $c == 34 then {x: ($x + {state:"string", nextstate:"ver2", string:("1."|explode), strpos:0, quote:$c}), tok: null}
		else error("yxml: syntax error (ver1)") end

	elif $x.state == "ver2" then
		if isNum($c) then {x: ($x + {state:"ver3"}), tok: null}
		else error("yxml: syntax error (ver2)") end

	elif $x.state == "ver3" then
		if isNum($c) then {x: $x, tok: null}
		elif $c == $x.quote then {x: ($x + {state:"xmldecl4"}), tok: null}
		else error("yxml: syntax error (ver3)") end

	elif $x.state == "xmldecl0" then
		if $c == 109 then {x: (appendname($x; $c) + {state:"xmldecl1"}), tok: null}
		elif isName($c) then {x: (appendname($x; $c) + {state:"pi1"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi4"}), tok: pistart_tok($x)}
		elif isSP($c) then {x: ($x + {state:"pi2"}), tok: pistart_tok($x)}
		else error("yxml: syntax error (xmldecl0)") end

	elif $x.state == "xmldecl1" then
		if $c == 108 then {x: (appendname($x; $c) + {state:"xmldecl2"}), tok: null}
		elif isName($c) then {x: (appendname($x; $c) + {state:"pi1"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"pi4"}), tok: pistart_tok($x)}
		elif isSP($c) then {x: ($x + {state:"pi2"}), tok: pistart_tok($x)}
		else error("yxml: syntax error (xmldecl1)") end

	elif $x.state == "xmldecl2" then
		if isSP($c) then {x: ((popname($x)) + {state:"xmldecl3"}), tok: null}
		elif isName($c) then {x: (appendname($x; $c) + {state:"pi1"}), tok: null}
		else error("yxml: syntax error (xmldecl2)") end

	elif $x.state == "xmldecl3" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 118 then {x: ($x + {state:"string", nextstate:"ver0", string:("ersion"|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (xmldecl3)") end

	elif $x.state == "xmldecl4" then
		if isSP($c) then {x: ($x + {state:"xmldecl5"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"xmldecl9"}), tok: null}
		else error("yxml: syntax error (xmldecl4)") end

	elif $x.state == "xmldecl5" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 63 then {x: ($x + {state:"xmldecl9"}), tok: null}
		elif $c == 101 then {x: ($x + {state:"string", nextstate:"enc0", string:("ncoding"|explode), strpos:0}), tok: null}
		elif $c == 115 then {x: ($x + {state:"string", nextstate:"std0", string:("tandalone"|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (xmldecl5)") end

	elif $x.state == "xmldecl6" then
		if isSP($c) then {x: ($x + {state:"xmldecl7"}), tok: null}
		elif $c == 63 then {x: ($x + {state:"xmldecl9"}), tok: null}
		else error("yxml: syntax error (xmldecl6)") end

	elif $x.state == "xmldecl7" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 63 then {x: ($x + {state:"xmldecl9"}), tok: null}
		elif $c == 115 then {x: ($x + {state:"string", nextstate:"std0", string:("tandalone"|explode), strpos:0}), tok: null}
		else error("yxml: syntax error (xmldecl7)") end

	elif $x.state == "xmldecl8" then
		if isSP($c) then {x: $x, tok: null}
		elif $c == 63 then {x: ($x + {state:"xmldecl9"}), tok: null}
		else error("yxml: syntax error (xmldecl8)") end

	elif $x.state == "xmldecl9" then
		if $c == 62 then {x: ($x + {state:"misc1"}), tok: null}
		else error("yxml: syntax error (xmldecl9)") end

	else error("yxml: internal error, unknown state \($x.state)")
	end;

# ---------- parse whole document into a token stream ----------
def step($x0; $ch):
	if $ch == 0 then error("yxml: syntax error (NUL)")
	elif $x0.ignore == $ch then
		{x: ($x0 + {ignore: 0}), tok: null}
	else
		($x0 + {ignore: (if $ch == 13 then 10 else 0 end)})
		| (if $ch == 10 or $ch == 13 then . + {line: (.line + 1), byte: 0} else . end)
		| . + {byte: (.byte + 1), total: (.total + 1)}
		| (if $ch == 13 then 10 else $ch end) as $c
		| dispatch(.; $c)
	end;

def initial($strict):
	{state:"init", stack:[], elem_pos:0, quote:0, nextstate:"",
	 ignore:0, string:[], strpos:0, reflen:0, data:[],
	 total:0, line:1, byte:0, strict:$strict};

def parse_tokens($chars; $strict):
	reduce $chars[] as $c (
		{x: initial($strict), tokens: []};
		(step(.x; $c)) as $r
		| {x: $r.x, tokens: (if $r.tok == null then .tokens else .tokens + [$r.tok] end)}
	)
	| if .x.state != "misc3" then error("yxml: unexpected end of input") else .tokens end;

# ---------- build JSONML from tokens ----------
def is_ws($s):
	($s | explode | map(select(. != 32 and . != 9 and . != 10 and . != 13)) | length) == 0;

def flush_text($b):
	if ($b.stack | length) == 0 then $b
	else
		($b.stack[-1]) as $f
		| if $f.text == "" then $b
			elif is_ws($f.text) then
				$b + {stack: ($b.stack[0:-1] + [$f + {text: ""}])}
			else
				$b + {stack: ($b.stack[0:-1] + [$f + {children: ($f.children + [$f.text]), text: ""}])}
			end
	end;

def finalize($f):
	if ($f.children | length) > 0 then [$f.name, $f.attrs, $f.children]
	else [$f.name, $f.attrs] end;

def build_jsonml($tokens):
	reduce $tokens[] as $tok (
		{stack: [], root: null, pending_attr: null, attr_buf: ""};
		if $tok.t == "elemstart" then
			(if (.stack | length) > 0 then flush_text(.) else . end)
			| .stack += [{name: $tok.name, attrs: {}, children: [], text: ""}]
		elif $tok.t == "attrstart" then
			. + {pending_attr: $tok.name, attr_buf: ""}
		elif $tok.t == "attrval" then
			. + {attr_buf: (.attr_buf + $tok.data)}
		elif $tok.t == "attrend" then
			. as $b
			| ($b.stack[-1]) as $f
			| $b + {stack: ($b.stack[0:-1] + [$f + {attrs: ($f.attrs + {($b.pending_attr): $b.attr_buf})}]), pending_attr: null, attr_buf: ""}
		elif $tok.t == "content" then
			if (.stack | length) > 0 then
				. as $b
				| ($b.stack[-1]) as $f
				| $b + {stack: ($b.stack[0:-1] + [$f + {text: ($f.text + $tok.data)}])}
			else . end
		elif $tok.t == "elemend" then
			. as $b
			| ($b | flush_text(.)) as $b2
			| ($b2.stack[-1]) as $f
			| (finalize($f)) as $node
			| ($b2 + {stack: ($b2.stack[0:-1])}) as $b3
			| if ($b3.stack | length) > 0 then
					($b3.stack[-1]) as $pf
					| $b3 + {stack: ($b3.stack[0:-1] + [$pf + {children: ($pf.children + [$node])}])}
				else $b3 + {root: $node} end
		else . end
	)
	| .root;

# ---------- entry point ----------
($ARGS.named.strict // false) as $strict
| (explode) as $chars
| (parse_tokens($chars; $strict)) as $tokens
| build_jsonml($tokens)