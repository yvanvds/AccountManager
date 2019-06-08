using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Google
{
    public class Account
    {
        public string UID { get; set; }
        public string GivenName { get; set; }
        public string FamilyName { get; set; }
        public string FullName { get => GivenName + " " + FamilyName; }

        public string Mail { get => UID.ToLower() + "@" + Connector.Domain; }
        public string MailAlias { get; set; }

        public bool IsStaff { get; set; } = false;

        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["uid"] = UID,
                ["givenName"] = GivenName,
                ["familyName"] = FamilyName,
                ["mailAlias"] = MailAlias,
                ["staff"] = IsStaff
            };
            return result;
        }

        public Account() { }

        public Account(JObject obj)
        {
            UID = obj.ContainsKey("uid") ? obj["uid"].ToString() : "";
            GivenName = obj.ContainsKey("givenName") ? obj["givenName"].ToString() : "";
            FamilyName = obj.ContainsKey("familyName") ? obj["familyName"].ToString() : "";
            MailAlias = obj.ContainsKey("mailAlias") ? obj["mailAlias"].ToString() : "";
            IsStaff = obj.ContainsKey("staff") ? obj["staff"].ToObject<bool>() : false;
        }
    }
}
