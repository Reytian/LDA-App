"""
Key section detector — locates paragraphs containing sensitive information in legal documents.

Legal contracts concentrate sensitive information in three predictable sections:
1. Definition clause (Recital + Definition): party definitions, abbreviations
2. Notice clause: addresses, phone numbers, emails
3. Signature page: signatory names, titles
"""

# Keywords for detecting key sections (Chinese + English)
KEYWORDS = [
    # Definition clause (Chinese)
    "鉴于", "定义", "释义", "以下简称", "指",
    # Definition clause (English)
    "RECITALS", "WHEREAS", "DEFINITIONS", "hereinafter", "shall mean",
    # Notice clause (Chinese)
    "通知", "送达", "联系方式",
    # Notice clause (English)
    "NOTICE", "NOTICES", "shall be sent to",
    # Signature page (Chinese)
    "签署", "签字", "盖章", "授权代表",
    # Signature page (English)
    "SIGNATURE", "IN WITNESS WHEREOF", "Executed", "By:", "Name:", "Title:",
]


def detect_key_sections(text: str) -> str:
    """
    Extract key sections from a legal document.

    Logic:
    1. Scan paragraphs for keyword matches
    2. For each match, extract the paragraph plus 2 paragraphs before/after as context
    3. If fewer than 3 keywords match, fall back to extracting first 15% + last 10%

    Args:
        text: Full document text

    Returns:
        Concatenated key section text
    """
    paragraphs = [p.strip() for p in text.split("\n") if p.strip()]

    if not paragraphs:
        return text

    # Find paragraphs containing keywords
    matched_indices = set()
    for i, paragraph in enumerate(paragraphs):
        for keyword in KEYWORDS:
            if keyword in paragraph:
                matched_indices.add(i)
                break

    # Fall back if too few matches
    if len(matched_indices) < 3:
        return _fallback_extraction(text)

    # Expand each match with +/- 2 paragraphs of context
    selected_indices = set()
    for idx in matched_indices:
        for offset in range(-2, 3):
            target = idx + offset
            if 0 <= target < len(paragraphs):
                selected_indices.add(target)

    selected_paragraphs = [
        paragraphs[i] for i in sorted(selected_indices)
    ]

    return "\n\n".join(selected_paragraphs)


def _fallback_extraction(text: str) -> str:
    """
    Fallback: extract first 15% + last 10% of the document.

    Args:
        text: Full document text

    Returns:
        Front and back portions concatenated
    """
    total_len = len(text)
    front_end = int(total_len * 0.15)
    back_start = int(total_len * 0.90)

    front_part = text[:front_end]
    back_part = text[back_start:]

    return front_part + "\n\n...\n\n" + back_part
