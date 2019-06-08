using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi.Rules
{
    public class DiscardSmartschoolGroup : IRule
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

        public Prop<string> ShortInfo { get; set; } = new Prop<string> { Value = "Groep: " };

        private string groupName;

        public bool Enabled { get; set; }

        public DiscardSmartschoolGroup()
        {
            SetDefaults();
        }

        public DiscardSmartschoolGroup(JObject obj)
        {
            SetDefaults();
            groupName = obj.ContainsKey("GroupName") ? obj["GroupName"].ToString() : "";
            ShortInfo.Value = "Groep: " + groupName;
        }

        private void SetDefaults()
        {
            rule = Rule.SS_DiscardGroup;
            ruleType = RuleType.SS_Import;
            ruleAction = RuleAction.Discard;
            header = "Negeer Groep";
            description = "Zorgt er voor dat deze groep niet geimporteerd zal worden.";
        }

        public void Modify(object obj)
        {
            // not needed
        }

        public void SetConfig(int ID, string data)
        {
            // we need only one piece of data here: the name of the group
            groupName = data;
            ShortInfo.Value = "Groep: " + groupName;
        }

        public string GetConfig(int ID)
        {
            return groupName;
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["Rule"] = rule.ToString(),
                ["GroupName"] = groupName
            };
            return result;
        }

        public bool ShouldApply(object obj)
        {
            if ((obj as Smartschool.Group).Name.Equals(groupName)) return true;
            return false;
        }
    }
}
