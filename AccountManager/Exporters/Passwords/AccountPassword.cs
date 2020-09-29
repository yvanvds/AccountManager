using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Exporters.Passwords
{
    public class AccountPassword : AbstractPassword
    {
        public string AccountName { get; }
        public string Mail { get; }
        public string Name { get; }
        public string ClassGroup { get; }
        public string ADPassword { get; }
        public string SSPassword { get; }

        public AccountPassword(string AccountName, string Name, string mail, string ClassGroup, string ADPassword, string SSPassword)
        {
            this.AccountName = AccountName;
            this.Name = Name;
            this.Mail = mail;
            this.ClassGroup = ClassGroup;
            this.ADPassword = ADPassword;
            this.SSPassword = SSPassword;
        }

        public AccountPassword(JObject obj)
        {
            AccountName = obj["AccountName"].ToString();
            Name = obj["Name"].ToString();
            Mail = obj["Mail"].ToString();
            ClassGroup = obj["ClassGroup"].ToString();
            ADPassword = obj["ADPassword"].ToString();
            SSPassword = obj["SSPassword"].ToString();
        }

        public override JObject ToJson()
        {
            return new JObject()
            {
                ["AccountName"] = AccountName,
                ["Name"] = Name,
                ["Mail"] = Mail,
                ["ClassGroup"] = ClassGroup,
                ["ADPassword"] = ADPassword,
                ["SSPassword"] = SSPassword,
            };
        }
    }
}
