using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using AbstractAccountApi;
using Newtonsoft.Json.Linq;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi.Rules
{
    public class MarkAsVirtual : IRule
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

        public Prop<string> ShortInfo { get; set; } = new Prop<string> { Value = "School: " };

        public bool Enabled { get; set; }

        public string GetConfig(int ID)
        {
            return schoolCode;
        }

        public void Modify(object obj)
        {
            
        }

        public void SetConfig(int ID, string data)
        {
            if (ID == 0) schoolCode = data;
            this.ShortInfo.Value = "School: " + schoolCode;
        }

        public bool ShouldApply(object obj)
        {
            var school = obj as Wisa.School;
            if (school != null)
            {
                return school.Name.Equals(schoolCode);
            }
            return false;
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["Rule"] = rule.ToString(),
                ["SchoolCode"] = schoolCode,
            };
            return result;
        }

        public MarkAsVirtual()
        {
            SetDefaults();
        }

        public MarkAsVirtual(JObject obj)
        {
            SetDefaults();
            this.schoolCode = obj.ContainsKey("SchoolCode") ? obj["SchoolCode"].ToString() : "";
            this.ShortInfo.Value = "School: " + schoolCode;
        }

        private void SetDefaults()
        {
            rule = Rule.WI_MarkAsVirtual;
            ruleType = RuleType.WISA_Import;
            ruleAction = RuleAction.WorkDate;
            header = "Markeer de school als virtueel";
            description = "Virtuele scholen kunnen een aangepaste werkdatum gebruiken. Dit helpt om inschrijvingen voor het volgende schooljaar in orde te brengen.";
        }

        private string schoolCode;
    }
}
