using System;
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
