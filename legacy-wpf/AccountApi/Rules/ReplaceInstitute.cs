using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi.Rules
{
    public class ReplaceInstitute : IRule
    {
        private Rule rule;
        public Rule Rule => rule;

        private RuleType ruleType;
        public RuleType RuleType => ruleType;

        private RuleAction ruleAction;
        public RuleAction RuleAction => ruleAction;

        private string header;
        public string Header => header;

        private string description;
        public string Description => description;

        public Prop<string> ShortInfo { get; set; } = new Prop<string> { Value = "Instellingsnummer: " };

        public bool Enabled { get; set; }

        public bool ShouldApply(object obj)
        {
            var group = obj as Wisa.ClassGroup;
            return (group.SchoolCode.Equals(original));
        }

        public string GetConfig(int ID)
        {
            if (ID == 0) return original;
            else return replacement;
        }

        public void Modify(object obj)
        {
            var group = obj as Wisa.ClassGroup;
            group.SchoolCode = replacement;
        }

        public void SetConfig(int ID, string data)
        {
            if (ID == 0) original = data;
            else replacement = data;
            this.ShortInfo.Value = "Instellingsnummer: " + original;
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["Rule"] = rule.ToString(),
                ["Original"] = original,
                ["Replacement"] = replacement
            };
            return result;
        }

        public ReplaceInstitute()
        {
            SetDefaults();
        }

        public ReplaceInstitute(JObject obj)
        {
            SetDefaults();
            this.original = obj.ContainsKey("Original") ? obj["Original"].ToString() : "";
            this.replacement = obj.ContainsKey("Replacement") ? obj["Replacement"].ToString() : "";
            this.ShortInfo.Value = "Instellingsnummer: " + original;
        }

        private void SetDefaults()
        {
            rule = Rule.WI_ReplaceInstitution;
            ruleType = RuleType.WISA_Import;
            ruleAction = RuleAction.Modify;
            header = "Vervang Instellingsnummer";
            description = "Vergang het WISA instellingsnummer bij het importeren. Dit kan handig zijn als je accounts wil toevoegen in een niet officiele instelling.";
        }

        private string original;
        private string replacement;
    }
}
