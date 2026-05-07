using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Rules
{
    public class ImportRules
    {
        public static Dictionary<Rule, string> WisaRules = new Dictionary<Rule, string>()
        {
            { Rule.WI_ReplaceInstitution, "Wijzig Instellingsnummer"},
            { Rule.WI_DontImportClass, "Klas niet Importeren" },
            { Rule.WI_MarkAsVirtual, "School Markeren als Virtueel" },
            { Rule.WI_DontImportUser, "Account niet Importeren" },
        };

        public static Dictionary<Rule, string> SmartschoolRules = new Dictionary<Rule, string>()
        {
            { Rule.SS_DiscardGroup, "Negeer Groep" },
            { Rule.SS_NoSubGroups, "Negeer SubGroepen" },
        };
    }
}
