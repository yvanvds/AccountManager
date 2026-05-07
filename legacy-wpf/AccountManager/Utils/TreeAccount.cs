using AccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Utils
{
    public class TreeAccount
    {
        public IAccount Base { get; private set; }
        public string Header { get; set; } = "Invalid Account";
        public string Icon { get; set; } = "GenderTransgender";

        public TreeAccount(IAccount Base)
        {
            this.Base = Base;
            if (Base == null) return;

            Header = Base.SurName + " " + Base.GivenName;
            if (Base.Gender == GenderType.Female)
            {
                Icon = "GenderFemale";
            }
            else if (Base.Gender == GenderType.Male)
            {
                Icon = "GenderMale";
            }
            else
            {
                Icon = "GenderTransgender";
            }
        }
    }
}
