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
            code = values[0];
            firstName = values[1];
            lastName = values[2];
        }

        public string CODE { get => code; }
        public string FirstName { get => firstName; }
        public string LastName { get => lastName; }
    }
}
