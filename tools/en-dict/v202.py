"""Reads and writes FUTO's static binary dictionaries (format 202, the main_xx.dict files).

The writer follows AOSP's makedict Ver2DictEncoder (tests/src/.../makedict) node for node,
plus the shortcut lists (e.g. "i" -> "I") that FUTO's dictionaries carry and that copy dropped.
`selftest.sh` checks that FUTO's main_en.dict decodes and re-encodes to the identical bytes.

A word is (frequency 0-255, not_a_word, possibly_offensive, [(shortcut target, frequency 0-15)]).
"""

MAGIC = b"\x9b\xc1\x3a\xfe"
VERSION = 202
F_MULTI, F_TERMINAL, F_SHORTCUT, F_BIGRAM, F_NOT_A_WORD, F_OFFENSIVE = (
    0x20,
    0x10,
    0x08,
    0x04,
    0x02,
    0x01,
)
END = 0x1F
MAX_WORD_LENGTH = (
    48  # DecoderSpecificConstants.DICTIONARY_MAX_WORD_LENGTH; longer words are dropped
)


def _raw_char(c):
    o = ord(c)
    return bytes([o]) if 0x20 <= o <= 0xFF else o.to_bytes(3, "big")


def _raw_string(s):
    return b"".join(map(_raw_char, s)) + bytes([END])


def _read_char(data, pos, table):
    b = data[pos]
    if b < 0x20:
        return chr(int.from_bytes(data[pos : pos + 3], "big")), pos + 3
    return (table[b - 0x20] if b - 0x20 < len(table) else chr(b)), pos + 1


def _read_string(data, pos, table=""):
    out = []
    while data[pos] != END:
        c, pos = _read_char(data, pos, table)
        out.append(c)
    return "".join(out), pos + 1


def decode(data):
    """Returns (header attributes in file order, {word: (freq, not_a_word, offensive, shortcuts)})."""
    assert data[:4] == MAGIC, "not a binary dictionary"
    assert int.from_bytes(data[4:6], "big") == VERSION, "not format 202"
    header_size = int.from_bytes(data[8:12], "big")
    attrs, pos = {}, 12
    while pos < header_size:
        key, pos = _read_string(data, pos)
        attrs[key], pos = _read_string(data, pos)
    table = attrs.pop("codePointTable", "")
    body = data[header_size:]
    words, stack = {}, [(0, "")]
    while stack:
        pos, prefix = stack.pop()
        count = body[pos]
        pos += 1
        if count & 0x80:
            count = (count & 0x7F) << 8 | body[pos]
            pos += 1
        for _ in range(count):
            flags = body[pos]
            if flags & F_MULTI:
                chars, pos = _read_string(body, pos + 1, table)
            else:
                chars, pos = _read_char(body, pos + 1, table)
            word = prefix + chars
            freq = None
            if flags & F_TERMINAL:
                freq = body[pos]
                pos += 1
            size = flags >> 6
            if size:
                stack.append(
                    (pos + int.from_bytes(body[pos : pos + size], "big"), word)
                )
                pos += size
            shortcuts = []
            if flags & F_SHORTCUT:
                end = pos + int.from_bytes(body[pos : pos + 2], "big")
                pos += 2
                while pos < end:
                    sflags = body[pos]
                    target, pos = _read_string(body, pos + 1)
                    shortcuts.append((target, sflags & 0x0F))
            assert not flags & F_BIGRAM, f"bigrams are not supported ({word!r})"
            if freq is not None:
                words[word] = (
                    freq,
                    bool(flags & F_NOT_A_WORD),
                    bool(flags & F_OFFENSIVE),
                    shortcuts,
                )
    return attrs, words


class _Node:
    __slots__ = ("addr", "chars", "children", "size", "word")

    def __init__(self, chars, word=None):
        self.chars, self.word, self.children = chars, word, None


class _Array:
    __slots__ = ("addr", "nodes", "size")

    def __init__(self, nodes):
        self.nodes = nodes


def _build(words, prefix=""):
    """Radix trie over sorted words; each array is ordered by first code point, as in FusionDictionary."""
    groups = {}
    for w in words:
        groups.setdefault(w[len(prefix)], []).append(w)
    nodes = []
    for first in sorted(groups, key=ord):
        group = groups[first]
        common = group[0]
        for w in group[1:]:
            i = len(prefix)
            while i < min(len(common), len(w)) and common[i] == w[i]:
                i += 1
            common = common[:i]
        node = _Node(common[len(prefix) :], common if common in words else None)
        rest = [w for w in group if w != common]
        if rest:
            node.children = _build({w: words[w] for w in rest}, common)
        nodes.append(node)
    return _Array(nodes)


def _flatten(array, out):
    out.append(array)
    for n in array.nodes:
        if n.children:
            _flatten(n.children, out)
    return out


def _byte_size(offset):
    a = abs(offset)
    return 1 if a <= 0xFF else 2 if a <= 0xFFFF else 3


def _count_size(n):
    assert n <= 0x7FFF
    return 1 if n <= 0x7F else 2


def encode(attrs, words):
    """attrs: header attributes in the order to write them; words: as returned by decode().
    Like FUTO's dictionaries, the output has no code point table (dicttool -t off)."""
    words = {w: v for w, v in words.items() if len(w) < MAX_WORD_LENGTH}

    def chars_size(n):
        return sum(len(_raw_char(c)) for c in n.chars) + (1 if len(n.chars) > 1 else 0)

    def shortcuts(n):
        sc = n.word and words[n.word][3]
        if not sc:
            return b""
        body = b"".join(
            bytes([(0x80 if i < len(sc) - 1 else 0) | f]) + _raw_string(t)
            for i, (t, f) in enumerate(sc)
        )
        return (len(body) + 2).to_bytes(2, "big") + body

    def head_size(
        n,
    ):  # flags, characters and frequency: everything before the children address
        return 1 + chars_size(n) + (1 if n.word else 0)

    flat = _flatten(_build(words), [])
    # Worst-case sizes first, then shrink the addresses until nothing moves (computeAddresses).
    offset = 0
    for a in flat:
        a.addr = offset
        pos = offset + _count_size(len(a.nodes))
        for n in a.nodes:
            n.size = head_size(n) + 3 + len(shortcuts(n))
            n.addr = pos
            pos += n.size
        a.size = pos - offset
        offset = pos
    before = {id(a): a.addr for a in flat}
    changed = True
    while changed:
        changed = False
        start = 0
        for a in flat:
            old_addr = before[id(a)]
            a.addr = start
            size = _count_size(len(a.nodes))
            for n in a.nodes:
                if start + size != n.addr:
                    changed = True
                n.addr = start + size
                node_size = head_size(n)
                if n.children:
                    target = n.children
                    if before[id(target)] < old_addr:  # already moved this pass
                        off = target.addr - (a.addr + node_size + size)
                    else:
                        off = before[id(target)] - (old_addr + node_size + size)
                    node_size += _byte_size(off)
                node_size += len(shortcuts(n))
                n.size = node_size
                size += node_size
            if size > a.size:
                raise RuntimeError("array grew")
            if size != a.size:
                a.size = size
                changed = True
            start += size
        before = {id(a): a.addr for a in flat}

    body = bytearray()
    for a in flat:
        assert len(body) == a.addr
        n_nodes = len(a.nodes)
        body += (
            (n_nodes | 0x8000).to_bytes(2, "big")
            if _count_size(n_nodes) == 2
            else bytes([n_nodes])
        )
        for n in a.nodes:
            assert len(body) == n.addr
            child_off = (
                n.children.addr - (n.addr + head_size(n)) if n.children else None
            )
            freq, not_a_word, offensive, sc = (
                words[n.word] if n.word else (0, False, False, [])
            )
            flags = (
                (F_MULTI if len(n.chars) > 1 else 0)
                | (F_TERMINAL if n.word else 0)
                | (_byte_size(child_off) << 6 if n.children else 0)
                | (F_SHORTCUT if sc else 0)
                | (F_NOT_A_WORD if not_a_word else 0)
                | (F_OFFENSIVE if offensive else 0)
            )
            body.append(flags)
            body += b"".join(map(_raw_char, n.chars))
            if len(n.chars) > 1:
                body.append(END)
            if n.word:
                body.append(freq)
            if n.children:
                body += child_off.to_bytes(_byte_size(child_off), "big")
            body += shortcuts(n)

    header = bytearray(MAGIC + VERSION.to_bytes(2, "big") + bytes(2) + bytes(4))
    for k, v in attrs.items():
        header += _raw_string(k) + _raw_string(v)
    header[8:12] = len(header).to_bytes(4, "big")
    return bytes(header + body)
