using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager
{
    public class Password
    {
        public string AccountName { get; }
        public string Name { get; }
        public string ClassGroup { get; }
        public string ADPassword { get; }
        public string SSPassword { get; }

        public Password(string AccountName, string Name, string ClassGroup, string ADPassword, string SSPassword)
        {
            this.AccountName = AccountName;
            this.Name = Name;
            this.ClassGroup = ClassGroup;
            this.ADPassword = ADPassword;
            this.SSPassword = SSPassword;
        }

        public Password(JObject obj)
        {
            AccountName = obj["AccountName"].ToString();
            Name = obj["Name"].ToString();
            ClassGroup = obj["ClassGroup"].ToString();
            ADPassword = obj["ADPassword"].ToString();
            SSPassword = obj["SSPassword"].ToString();
        }

        public JObject ToJson()
        {
            return new JObject()
            {
                ["AccountName"] = AccountName,
                ["Name"] = Name,
                ["ClassGroup"] = ClassGroup,
                ["ADPassword"] = ADPassword,
                ["SSPassword"] = SSPassword,
            };
        }
    }
}
