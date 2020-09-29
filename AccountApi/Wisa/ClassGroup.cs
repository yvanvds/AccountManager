using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public class ClassGroup
    {
        private readonly string name;
        private readonly string groupName;
        private readonly string description;
        private readonly string adminCode;
        private string schoolCode;

        public ClassGroup(string data, int schoolID)
        {
            string[] values = data.Split(',');
            name = values[0];
            groupName = values[1];
            description = values[2];
            adminCode = values[3];
            schoolCode = values[4];
            SchoolID = schoolID;

            if (Connector.ReplaceInstNumber.ContainsKey(schoolCode))
            {
                schoolCode = Connector.ReplaceInstNumber[schoolCode];
            }
        }

        public string Name { get => name; }
        public string GroupName { get => groupName; }
        public string FullName { get
            {
                string result = name;
                if (GroupName != "00")
                {
                    result += " " + GroupName;
                }
                return result;
            } 
        }
        public int Year
        {
            get
            {
                return (int)char.GetNumericValue(Name[0]);
            }
        }
        public string Description { get => description; }
        public string AdminCode { get => adminCode; }
        public string SchoolCode { get => schoolCode; set => schoolCode = value; }

        public int SchoolID { get; }

        public bool ContainsStudents()
        {
            foreach (var student in Students.All)
            {
                if (student.ClassGroup == Name) return true;
            }
            return false;
        }

        public JObject ToJson()
        {


            JObject result = new JObject
            {
                ["Name"] = Name,
                ["GroupName"] = GroupName,
                ["Description"] = Description,
                ["AdminCode"] = AdminCode,
                ["SchoolCode"] = SchoolCode,
                ["SchoolID"] = SchoolID
            };
            return result;
        }

        public ClassGroup(JObject obj)
        {
            name = obj["Name"].ToString();
            groupName = obj["GroupName"]?.ToString();
            description = obj["Description"].ToString();
            adminCode = obj["AdminCode"].ToString();
            schoolCode = obj["SchoolCode"].ToString();
            SchoolID = Convert.ToInt32(obj["SchoolID"]);
        }
    }
}
