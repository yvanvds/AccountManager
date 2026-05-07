using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi.Rules
{
    public class DontImportClass : IRule
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

        public Prop<string> ShortInfo { get; set; } = new Prop<string> { Value = "Klas: " };

        public bool Enabled { get; set; }

        public string GetConfig(int ID)
        {
            return className;
        }

        public void Modify(object obj)
        {

        }

        public void SetConfig(int ID, string data)
        {
            className = data;
            this.ShortInfo.Value = "Klas: " + className;
        }

        public bool ShouldApply(object obj)
        {
            var group = obj as Wisa.ClassGroup;
            return group.Name.Equals(className);
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["Rule"] = rule.ToString(),
                ["ClassName"] = className
            };
            return result;
        }

        public DontImportClass()
        {
            SetDefaults();
        }

        public DontImportClass(JObject obj)
        {
            SetDefaults();
            this.className = obj.ContainsKey("ClassName") ? obj["ClassName"].ToString() : "";
            this.ShortInfo.Value = "Klas: " + className;
        }

        private void SetDefaults()
        {
            rule = Rule.WI_DontImportClass;
            ruleType = RuleType.WISA_Import;
            ruleAction = RuleAction.Discard;
            header = "Klas niet Importeren";
            description = "Sla deze klas over bij het importeren uit Wisa.";
        }

        private string className;
    }
}
