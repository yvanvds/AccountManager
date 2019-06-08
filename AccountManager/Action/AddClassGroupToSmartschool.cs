using AbstractAccountApi;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Threading.Tasks;

namespace AccountManager.Action
{
    class AddClassGroupToSmartschool : GroupAction
    {
        public override Task Apply(LinkedGroup linkedGroup)
        {
            throw new NotImplementedException();
        }

        public AddClassGroupToSmartschool() : base(
            "Klas toevoegen aan Smartschool",
            "Voeg deze klas toe aan Smartschool.",
            true)
        {
        }


    }
}
