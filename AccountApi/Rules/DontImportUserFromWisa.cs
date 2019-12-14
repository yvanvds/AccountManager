using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using static AbstractAccountApi.ObservableProperties;

namespace AccountApi.Rules
{
    public class DontImportUserFromWisa : IRule
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

        public Prop<string> ShortInfo { get; set; } = new Prop<string> { Value = "Account: " };

        public bool Enabled { get; set; }

        public string GetConfig(int ID)
        {
            return userName;
        }

        public void Modify(object obj)
        {

        }

        public void SetConfig(int ID, string data)
        {
            userName = data;
            this.ShortInfo.Value = "Account: " + userName;
        }

        public bool ShouldApply(object obj)
        {
            var account = obj as Wisa.Staff;
            return account.CODE.Equals(userName);
        }

        public JObject ToJson()
        {
            var result = new JObject
            {
                ["Rule"] = rule.ToString(),
                ["UserName"] = userName
            };
            return result;
        }

        public DontImportUserFromWisa()
        {
            SetDefaults();
        }

        public DontImportUserFromWisa(JObject obj)
        {
            SetDefaults();
            this.userName = obj.ContainsKey("UserName") ? obj["UserName"].ToString() : "";
            this.ShortInfo.Value = "Account: " + userName;
        }

        private void SetDefaults()
        {
            rule = Rule.WI_DontImportUser;
            ruleType = RuleType.WISA_Import;
            ruleAction = RuleAction.Discard;
            header = "Account niet Importeren";
            description = "Dit account niet importeren uit Wisa.";
        }

        private string userName;
    }
}
