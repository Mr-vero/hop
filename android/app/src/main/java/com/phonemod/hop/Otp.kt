package com.phonemod.hop

/** Finds a one-time code in notification text. Works for Indonesian and English messages. */
object Otp {
    private val keyword = Regex(
        "(?i)(otp|kode|code|verif|token|\\bpin\\b|sandi|passcode|password|one[- ]time|2fa|authenticat)"
    )
    // Money ("Rp 250.000", "IDR 1,000") must never be mistaken for a code
    private val money = Regex("(?i)(rp|idr|usd|\\$)\\.?\\s?[\\d.,]+")
    // Separators only join numbers when digits sit on both sides: "1.000", "27-10-2026" and "14:30" are
    // not codes, but "G-739104", "code: 5531," and "482913." are
    private val candidate = Regex("(?<![\\d/:]|\\d[.,-])(\\d{3}[- ]\\d{3}|\\d{4,8})(?![\\d/:]|[.,-]\\d)")

    fun find(text: String): String? {
        if (!keyword.containsMatchIn(text)) return null
        val codes = candidate.findAll(money.replace(text, " "))
            .map { it.value.filter(Char::isDigit) }
            .filter { it.length in 4..8 }
            .toList()
        // Six digits is by far the most common code length, so prefer it
        return codes.firstOrNull { it.length == 6 } ?: codes.firstOrNull()
    }
}
