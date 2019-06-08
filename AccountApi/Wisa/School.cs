using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public class School
    {
        private readonly int id;
        private readonly string name;
        private readonly string description;

        public School(int ID, string Name, string Description)
        {
            id = ID;
            name = Name;
            description = Description;
        }

        public int ID { get => id; }
        public string Name { get => name; }
        public string Description { get => description; }

        public bool IsActive { get; set; } = false;

        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["ID"] = ID,
                ["Name"] = Name,
                ["Description"] = Description,
                ["IsActive"] = IsActive
            };
            return result;
        }

        public School(JObject obj)
        {
            id = Convert.ToInt32(obj["ID"]);
            name = obj["Name"].ToString();
            description = obj["Description"].ToString();
            IsActive = Convert.ToBoolean(obj["IsActive"]);
        }
    }
}
