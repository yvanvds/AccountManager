using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public class Staff
    {
        private readonly string code;
        private readonly string firstName;
        private readonly string lastName;
        private readonly string wisaID;

        public Staff(string data)
        {
            string[] values = data.Split(',');
            code = values[0].Trim();
            wisaID = values[1].Trim();
            lastName = values[2].Trim();
            firstName = values[3].Trim();
        }

        public string WisaID { get => wisaID;}
        public string CODE { get => code; }
        public string FirstName { get => firstName; }
        public string LastName { get => lastName; }

        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["Code"] = CODE,
                ["WisaID"] = WisaID,
                ["FirstName"] = FirstName,
                ["LastName"] = LastName,
            };
            return result;
        }

        public Staff(JObject obj)
        {
            code = obj["Code"].ToString();
            wisaID = obj.ContainsKey("WisaID") ? obj["WisaID"].ToString() : "";
            firstName = obj["FirstName"].ToString();
            lastName = obj["LastName"].ToString();
        }
    }
}
