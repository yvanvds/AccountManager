﻿using Newtonsoft.Json.Linq;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountApi.Wisa
{
    public class Student
    {
        private readonly string classGroup;
        private readonly string classSubGroup;
        private readonly string name;
        private readonly string firstname;
        private readonly DateTime dateOfBirth;
        private readonly string wisaID;
        private readonly string stemID;
        private readonly GenderType gender;
        private readonly string stateID;
        private readonly string placeOfBirth;
        private readonly string nationality;
        private readonly string street;
        private readonly string houseNumber;
        private readonly string houseNumberAdd;
        private readonly string postalCode;
        private readonly string city;
        private readonly DateTime classChange;

        public Student(string data, int schoolID)
        {
            string[] values = data.Split(',');
            classGroup = values[0].Trim();
            classSubGroup = values[1].Trim();
            name = values[2].Trim();
            firstname = values[3].Trim();
            dateOfBirth = DateTime.ParseExact(values[4].Trim(), "d/M/yyyy", CultureInfo.InvariantCulture);
            wisaID = values[5].Trim();
            stemID = values[6].Trim();
            gender = values[7].Trim().Equals("M") ? GenderType.Male : GenderType.Female;
            stateID = values[8].Trim();
            placeOfBirth = values[9].Trim();
            nationality = values[10].Trim();
            street = values[11].Trim();
            houseNumber = values[12].Trim();
            houseNumberAdd = values[13].Trim();
            postalCode = values[14].Trim();
            city = values[15].Trim();
            classChange = DateTime.ParseExact(values[16].Trim(), "d/M/yyyy", CultureInfo.InvariantCulture);
            SchoolID = schoolID;
        }

        /// <summary>
        /// The student's class
        /// </summary>
        public string ClassGroup { get => classGroup; }
        public string ClassSubGroup { get => classSubGroup; }

        public string ClassName
        {
            get
            {
                string result = ClassGroup;
                if (ClassGroupManager.UseSubGroups(ClassGroup))
                {
                    result += " " + ClassSubGroup;
                }
                return result;
            }
        }

        /// <summary>
        /// The student's family name
        /// </summary>
        public string Name { get => name; }

        /// <summary>
        /// The student's first name
        /// </summary>
        public string FirstName { get => firstname; }

        public string FullName { get => firstname + " " + name; }

        /// <summary>
        /// The student's date of birth
        /// </summary>
        public DateTime DateOfBirth { get => dateOfBirth; }

        /// <summary>
        /// The student's ID according to Wisa
        /// </summary>
        public string WisaID { get => wisaID; }

        /// <summary>
        /// The student's 'stamboeknummer'
        /// </summary>
        public string StemID { get => stemID; } // stamboeknummer

        /// <summary>
        /// The student's Gender
        /// </summary>
        public GenderType Gender { get => gender; }

        /// <summary>
        /// The student's State ID (rijksregister)
        /// </summary>
        public string StateID { get => stateID; } // rijksregisternummer

        /// <summary>
        /// City where this student is born
        /// </summary>
        public string PlaceOfBirth { get => placeOfBirth; }

        /// <summary>
        /// Student's nationality
        /// </summary>
        public string Nationality { get => nationality; }

        /// <summary>
        /// The street where this student lives
        /// </summary>
        public string Street { get => street; }

        /// <summary>
        /// The house number of the street where this student lives
        /// </summary>
        public string HouseNumber { get => houseNumber; }

        /// <summary>
        /// Add this to the house number (could be bus number)
        /// </summary>
        public string HouseNumberAdd { get => houseNumberAdd; }

        /// <summary>
        /// The postal code of the student's address
        /// </summary>
        public string PostalCode { get => postalCode; }

        /// <summary>
        /// The city where the student lives
        /// </summary>
        public string City { get => city; }

        /// <summary>
        /// The official date of the student's most recent class change
        /// </summary>
        public DateTime ClassChange { get => classChange; }

        /// <summary>
        /// The ID of the school this student belongs to
        /// </summary>
        public int SchoolID { get; }

        public JObject ToJson()
        {
            JObject result = new JObject
            {
                ["ClassGroup"] = ClassGroup,
                ["ClassSubGroup"] = ClassSubGroup,
                ["Name"] = Name,
                ["FirstName"] = FirstName,
                ["DateOfBirth"] = Utils.DateToString(DateOfBirth),
                ["WisaID"] = WisaID,
                ["StemID"] = StemID,
                ["Gender"] = Gender.ToString(),
                ["StateID"] = StateID,
                ["PlaceOfBirth"] = PlaceOfBirth,
                ["Nationality"] = Nationality,
                ["Street"] = Street,
                ["HouseNumber"] = HouseNumber,
                ["HouseNumberAdd"] = HouseNumberAdd,
                ["PostalCode"] = PostalCode,
                ["City"] = City,
                ["ClassChange"] = Utils.DateToString(ClassChange),
                ["SchoolID"] = SchoolID
            };
            return result;
        }

        public Student(JObject obj)
        {
            classGroup = obj["ClassGroup"].ToString();
            classSubGroup = obj["ClassSubGroup"]?.ToString();
            name = obj["Name"].ToString();
            firstname = obj["FirstName"].ToString();
            dateOfBirth = Utils.StringToDate(obj["DateOfBirth"].ToString());
            wisaID = obj["WisaID"].ToString();
            stemID = obj["StemID"].ToString();
            string gType = obj["Gender"].ToString();
            switch (gType)
            {
                case "Male": gender = GenderType.Male; break;
                case "Female": gender = GenderType.Female; break;
                case "Transgender": gender = GenderType.Transgender; break;
            }
            stateID = obj["StateID"].ToString();
            placeOfBirth = obj["PlaceOfBirth"].ToString();
            nationality = obj["Nationality"].ToString();
            street = obj["Street"].ToString();
            houseNumber = obj["HouseNumber"].ToString();
            houseNumberAdd = obj["HouseNumberAdd"].ToString();
            postalCode = obj["PostalCode"].ToString();
            city = obj["City"].ToString();
            classChange = Utils.StringToDate(obj["ClassChange"].ToString());
            SchoolID = Convert.ToInt32(obj["SchoolID"]);
        }
    }
}
