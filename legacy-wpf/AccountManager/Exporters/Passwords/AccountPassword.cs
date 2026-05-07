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
        public string SSPassword { get; }
        public string AzurePassword { get; }

        public AccountPassword(string AccountName, string Name, string mail, string ClassGroup, string SSPassword, string azurePassword)
        {
            this.AccountName = AccountName;
            this.Name = Name;
            this.Mail = mail;
            this.ClassGroup = ClassGroup;
            this.SSPassword = SSPassword;
            AzurePassword = azurePassword;
        }

        public AccountPassword(JObject obj)
        {
            AccountName = obj["AccountName"].ToString();
            Name = obj["Name"].ToString();
            Mail = obj["Mail"].ToString();
            ClassGroup = obj["ClassGroup"].ToString();
            SSPassword = obj["SSPassword"].ToString();
            AzurePassword = obj["AzurePassword"].ToString();
        }

        public override JObject ToJson()
        {
            return new JObject()
            {
                ["AccountName"] = AccountName,
                ["Name"] = Name,
                ["Mail"] = Mail,
                ["ClassGroup"] = ClassGroup,
                ["SSPassword"] = SSPassword,
                ["AzurePassword"] = AzurePassword,
            };
        }
    }
}
