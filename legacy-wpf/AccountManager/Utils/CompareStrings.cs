using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    internal class CompareStrings
    {
        static readonly Regex WsCollapse = new Regex(@"\s+", RegexOptions.Compiled);

        static string Canonicalize(string s)
        {
            if (s == null) return null;

            // 1) Unicode normalization
            s = s.Normalize(NormalizationForm.FormKC);

            // 2) Remove zero-width characters
            s = s.Replace("\u200B", "") // zero width space
                 .Replace("\u200C", "") // ZWNJ
                 .Replace("\u200D", "") // ZWJ
                 .Replace("\uFEFF", ""); // BOM

            // 3) Map NBSP and other “space-likes” to a normal space
            s = s.Replace('\u00A0', ' ')     // NBSP
                 .Replace('\u2007', ' ')     // figure space
                 .Replace('\u202F', ' ');    // narrow NBSP

            // 4) Collapse any whitespace runs to a single space
            s = WsCollapse.Replace(s, " ");

            // 5) Trim
            return s.Trim();
        }

        public static bool NamesEqual(string a, string b)
        {
            var ca = Canonicalize(a);
            var cb = Canonicalize(b);
            // choose Ordinal or OrdinalIgnoreCase depending on your rule
            return string.Equals(ca, cb, StringComparison.Ordinal);
        }
    }
}
