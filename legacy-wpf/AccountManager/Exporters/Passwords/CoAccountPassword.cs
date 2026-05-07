using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Exporters.Passwords
{
    public class CoAccountPassword : AbstractPassword
    {
        public string AccountName { get; }
        public string Name { get; }
        public string ClassGroup { get; }

        public string Co1 { get; set; }
        public string Co2 { get; set; }
        public string Co3 { get; set; }
        public string Co4 { get; set; }
        public string Co5 { get; set; }
        public string Co6 { get; set; }


        public string GetCSV()
        {
            return AccountName + ";" + Name + ";" + ClassGroup + ";" + Co1 + ";" + Co2 + ";" + Co3 + ";" + Co4 + ";" + Co5 + ";" + Co6;
        }

        public CoAccountPassword(string AccountName, string Name, string ClassGroup)
        {
            this.AccountName = AccountName;
            this.Name = Name;
            this.ClassGroup = ClassGroup;
        }

        public CoAccountPassword(JObject obj)
        {
            AccountName = obj["AccountName"].ToString();
            Name = obj["Name"].ToString();
            ClassGroup = obj["ClassGroup"].ToString();
            Co1 = obj["Co1"].ToString();
            Co2 = obj["Co2"].ToString();
            Co3 = obj["Co3"].ToString();
            Co4 = obj["Co4"].ToString();
            Co5 = obj["Co5"].ToString();
            Co6 = obj["Co6"].ToString();
        }

        public override JObject ToJson()
        {
            return new JObject()
            {
                ["AccountName"] = AccountName,
                ["Name"] = Name,
                ["ClassGroup"] = ClassGroup,
                ["Co1"] = Co1,
                ["Co2"] = Co2,
                ["Co3"] = Co3,
                ["Co4"] = Co4,
                ["Co5"] = Co5,
                ["Co6"] = Co6,
            };
        }
    }
}
