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

        public Staff(string data)
        {
            string[] values = data.Split(',');
            code = values[0].Trim();
            lastName = values[1].Trim();
            firstName = values[2].Trim();
        }

        public string CODE { get => code; }
        public string FirstName { get => firstName; }
        public string LastName { get => lastName; }

        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["Code"] = CODE,
                ["FirstName"] = FirstName,
                ["LastName"] = LastName,
            };
            return result;
        }

        public Staff(JObject obj)
        {
            code = obj["Code"].ToString();
            firstName = obj["FirstName"].ToString();
            lastName = obj["LastName"].ToString();
        }
    }
}
